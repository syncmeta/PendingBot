import { beforeEach, describe, expect, it, vi } from 'vitest';

// We mock @cloudflare/sandbox before importing the wrapper so the
// `getSandbox` factory returned to runPython is the spy below — no
// container needs to actually start under vitest.
const runCodeMock = vi.fn();
const getSandboxMock = vi.fn(() => ({
  runCode: runCodeMock,
}));
vi.mock('@cloudflare/sandbox', () => ({
  getSandbox: (...args: unknown[]) => getSandboxMock(...(args as Parameters<typeof getSandboxMock>)),
}));

// Wallet client — gate/debit spies so we can assert the Phase F billing
// hooks fire without a real WalletDO.
const gateMock = vi.fn();
const debitMock = vi.fn();
vi.mock('../billing/wallet-client', () => ({
  wallet: {
    gate: (...args: unknown[]) => gateMock(...args),
    debit: (...args: unknown[]) => debitMock(...args),
  },
}));

// 群消费路由到 settleGroupSpend(实缴池+认缴分账);此处只验"群→调它",
// 其内部逻辑由 billing/group-wallet.test.ts 覆盖。
const settleGroupSpendMock = vi.fn((..._args: unknown[]) => Promise.resolve(undefined));
vi.mock('../billing/group-wallet', () => ({
  settleGroupSpend: (...args: unknown[]) => settleGroupSpendMock(...args),
}));

// serviceClient → a Supabase stub whose conversations lookup returns a
// 1v1 conversation (so resolveSandboxBillingSubjectId falls back to the
// passed userId as the billing subject).
type ConvRow = { conversation_type: string; responsible_subject_id: string | null };
const conversationTypeMock = vi.fn(
  (): ConvRow => ({
    conversation_type: 'private',
    responsible_subject_id: null,
  }),
);
vi.mock('./supabase', () => ({
  serviceClient: () => ({
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => ({ data: conversationTypeMock() }),
        }),
      }),
    }),
  }),
}));

import { runPython, SandboxGateError } from './sandbox';
import type { Env } from '../types';

const env = {
  Sandbox: {} as unknown,
} as unknown as Env;

describe('Cloudflare sandbox wrapper', () => {
  beforeEach(() => {
    runCodeMock.mockReset();
    getSandboxMock.mockClear();
    gateMock.mockReset();
    debitMock.mockReset();
    conversationTypeMock.mockReturnValue({
      conversation_type: 'private',
      responsible_subject_id: null,
    });
  });

  it('routes runPython to the conversation-keyed sandbox and joins logs', async () => {
    runCodeMock.mockResolvedValueOnce({
      logs: { stdout: ['hello\n'], stderr: [] },
      results: [],
      executionCount: 1,
    });

    const result = await runPython(env, 'conv-1', 'print("hello")');

    expect(getSandboxMock).toHaveBeenCalledWith(env.Sandbox, 'conv-1', expect.objectContaining({
      sleepAfter: expect.any(String),
    }));
    expect(runCodeMock).toHaveBeenCalledWith('print("hello")', {
      language: 'python',
      timeout: 30_000,
    });
    expect(result).toEqual({
      stdout: 'hello\n',
      exitCode: 0,
      truncated: false,
    });
  });

  it('surfaces a runCode error with exitCode 1 and traceback in stdout', async () => {
    runCodeMock.mockResolvedValueOnce({
      logs: { stdout: [], stderr: [] },
      results: [],
      executionCount: 2,
      error: {
        name: 'ZeroDivisionError',
        message: 'division by zero',
        traceback: ['Traceback (most recent call last):', '  …', 'ZeroDivisionError: division by zero'],
      },
    });

    const result = await runPython(env, 'conv-1', '1/0');

    expect(result.exitCode).toBe(1);
    expect(result.stdout).toContain('ZeroDivisionError: division by zero');
    expect(result.stdout).toContain('Traceback');
  });

  describe('Phase F billing', () => {
    it('skips gate + debit when no meter is given', async () => {
      runCodeMock.mockResolvedValueOnce({
        logs: { stdout: ['ok\n'], stderr: [] },
        results: [],
        executionCount: 1,
      });

      await runPython(env, 'conv-1', 'print("ok")');

      expect(gateMock).not.toHaveBeenCalled();
      expect(debitMock).not.toHaveBeenCalled();
    });

    it('gates before running and debits wall-clock seconds after', async () => {
      gateMock.mockResolvedValueOnce({ balanceMicros: 1_000_000, thresholdState: 'sufficient' });
      debitMock.mockResolvedValueOnce({ balanceMicros: 999_000, thresholdState: 'sufficient' });
      runCodeMock.mockImplementationOnce(async () => {
        // burn a little wall-clock so elapsedSeconds > 0
        await new Promise((r) => setTimeout(r, 20));
        return { logs: { stdout: ['done\n'], stderr: [] }, results: [], executionCount: 1 };
      });

      const result = await runPython(env, 'conv-1', 'print("done")', {
        meter: { userId: 'user-42' },
      });

      // gate ran with the resolved subject (1v1 → userId) BEFORE runCode
      expect(gateMock).toHaveBeenCalledWith(env, 'user-42');
      // gate ran before runCode (compare invocation order)
      expect(gateMock.mock.invocationCallOrder[0]).toBeLessThan(
        runCodeMock.mock.invocationCallOrder[0],
      );
      // debit fired with the sandbox_runtime category + a per-run dedupeId
      expect(debitMock).toHaveBeenCalledTimes(1);
      const [, subjectArg, pncArg, optsArg] = debitMock.mock.calls[0];
      expect(subjectArg).toBe('user-42');
      expect(pncArg).toBeGreaterThan(0);
      expect(optsArg.category).toBe('sandbox_runtime');
      expect(optsArg.dedupeId).toMatch(/^sandbox:conv-1:\d+$/);
      expect(result.stdout).toBe('done\n');
    });

    it('throws SandboxGateError and never runs code when exhausted', async () => {
      gateMock.mockResolvedValueOnce({ balanceMicros: -5, thresholdState: 'exhausted' });

      await expect(
        runPython(env, 'conv-1', 'print("nope")', { meter: { userId: 'user-42' } }),
      ).rejects.toBeInstanceOf(SandboxGateError);

      expect(runCodeMock).not.toHaveBeenCalled();
      expect(debitMock).not.toHaveBeenCalled();
    });

    it('群会话:pre-gate 读群 subject + 扣费走 settleGroupSpend(非直接 wallet.debit)', async () => {
      conversationTypeMock.mockReturnValue({
        conversation_type: 'group',
        responsible_subject_id: 'subject-group-7',
      });
      gateMock.mockResolvedValueOnce({ balanceMicros: 1_000_000, thresholdState: 'sufficient' });
      runCodeMock.mockImplementationOnce(async () => {
        await new Promise((r) => setTimeout(r, 20));
        return { logs: { stdout: [], stderr: [] }, results: [], executionCount: 1 };
      });

      await runPython(env, 'conv-1', 'pass', { meter: { userId: 'user-42' } });

      // pre-exec gate 仍按群 subject 读
      expect(gateMock).toHaveBeenCalledWith(env, 'subject-group-7');
      // 群消费走 settleGroupSpend(实缴池+认缴分账),不再直接 wallet.debit(group)
      expect(settleGroupSpendMock).toHaveBeenCalledTimes(1);
      const arg = settleGroupSpendMock.mock.calls[0][0] as { subjectId: string; spendMicros: number; category: string };
      expect(arg.subjectId).toBe('subject-group-7');
      expect(arg.spendMicros).toBeGreaterThan(0);
      expect(arg.category).toBe('sandbox_runtime');
      expect(debitMock).not.toHaveBeenCalled();
    });
  });
});
