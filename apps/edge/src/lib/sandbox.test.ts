import { describe, expect, it, vi } from 'vitest';

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

import { runPython } from './sandbox';
import type { Env } from '../types';

const env = {
  Sandbox: {} as unknown,
} as unknown as Env;

describe('Cloudflare sandbox wrapper', () => {
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
});
