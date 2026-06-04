import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
} from '../../tests/_helpers/fake-supabase';

// Mock the Langfuse seam so we observe what persistAuditMessage hands it,
// independent of whether LANGFUSE_* keys are set. Reference the spy lazily
// (vi.mock is hoisted above the const → TDZ otherwise).
const traceMock = vi.fn(async (_env: unknown, _args: unknown) => {});
vi.mock('../lib/llm-trace', () => ({
  traceGeneration: (env: unknown, args: unknown) => traceMock(env, args),
}));

installFakeSupabaseMock();

import { persistAuditMessage } from './router';

const AUDIT_ID = '018f2222-2222-7222-8222-222222222222';

function auditMessage() {
  return {
    auditId: AUDIT_ID,
    latencyMs: 42,
    route: {
      modelToCall: 'openai/gpt-5-mini',
      provider: { slug: 'openrouter', apiStyle: 'chat' },
    },
    opts: {
      taskType: 'crew_turn',
      status: 'success',
      conversationId: 'conv-1',
      userId: 'user-9',
      providerCostUsd: 0.01,
      inputTokens: 100,
      outputTokens: 20,
      promptBody: [{ role: 'user', content: 'hi' }],
      completionBody: 'hello there',
    },
  } as never;
}

describe('persistAuditMessage → Langfuse trace wiring', () => {
  beforeEach(() => traceMock.mockClear());

  it('emits one generation per turn with model/tokens/cost/latency + full input/output content', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'conv-1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
    });

    await persistAuditMessage(makeFakeEnv(db), auditMessage());

    expect(traceMock).toHaveBeenCalledTimes(1);
    const [, args] = traceMock.mock.calls[0] as [unknown, Record<string, unknown>];
    expect(args).toMatchObject({
      name: 'crew_turn',
      model: 'openai/gpt-5-mini',
      traceId: AUDIT_ID,
      userId: 'user-9',
      sessionId: 'conv-1',
      usage: { input: 100, output: 20, total: 120 },
    });
    expect(args.metadata).toMatchObject({
      task_type: 'crew_turn',
      provider: 'openrouter',
      status: 'success',
      latency_ms: 42,
      cost_usd: 0.01,
    });
    // Full-functionality tracing (#248): Langfuse is first-party in the stack,
    // so traces carry the full prompt/completion bodies for debugging.
    expect(args.input).toEqual([{ role: 'user', content: 'hi' }]);
    expect(args.output).toEqual('hello there');
  });

  // NOTE on idempotency: the trace call sits AFTER persistAuditMessage's
  // duplicate-delivery early-return (audit_log upsert with ignoreDuplicates →
  // empty result set → `return`), so a retried queue message never re-traces.
  // That guard isn't exercised here because the fake supabase doesn't model
  // ignoreDuplicates (it returns a row on every upsert); the real DB unique
  // index does. The ordering is asserted by code review, not this fixture.
});
