import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type Row,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// GET /v1/conversations/:id/model — wire contract for the blind-box state
// the iOS header pill reads.

vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<{
    Bindings: { SUPABASE_URL: string; SUPABASE_JWT_SECRET: string };
    Variables: { userId?: string; userJwt?: string };
  }> => async (c, next) => {
    c.set('userId', 'user-1');
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

// Membership + bot resolution are KV-cache-backed; stub them so the test is
// about the response shape, not the cache.
vi.mock('../src/lib/conv-cache', () => ({
  resolveConv: vi.fn(async () => ({ id: CONV_ID, bot_id: 'bot-1' })),
  deleteCachedConv: vi.fn(async () => undefined),
}));
const botConfig = { value: {} as Record<string, unknown> };
vi.mock('../src/lib/bot-cache', () => ({
  resolveBot: vi.fn(async () => ({
    id: 'bot-1',
    model_id: 'anthropic/claude-x',
    model_provider: 'openrouter',
    config: botConfig.value,
  })),
}));

installFakeSupabaseMock();

const CONV_ID = '11111111-2222-4333-8444-555555555555';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let conversationModelRoutes: any;

beforeEach(async () => {
  botConfig.value = {};
  ({ conversationModelRoutes } = await import('../src/routes/conversation-model-routes'));
});

async function getState(conv: Row): Promise<Record<string, unknown>> {
  const db = makeFakeDb({ conversations: [conv] });
  const app = new Hono<AppBindings>();
  app.route('/v1/conversations', conversationModelRoutes);
  const res = await app.request(`/v1/conversations/${CONV_ID}/model`, {}, makeFakeEnv(db));
  expect(res.status).toBe(200);
  return (await res.json()) as Record<string, unknown>;
}

const conv = (revealed: boolean): Row => ({
  id: CONV_ID,
  current_model_slug: 'anthropic/claude-x',
  current_model_provider: 'openrouter',
  model_revealed: revealed,
});

describe('GET /v1/conversations/:id/model', () => {
  it('reports model_revealed as the raw conversation fact under a disclose bot', async () => {
    // Used to fold disclose into model_revealed:true. The client already ORs
    // in reveal_mode itself, and the global 「总是盲盒」 setting needs to tell
    // "this conversation was actually revealed" (irreversible) apart from
    // "the bot just doesn't hide it" (overridable). Folding loses that.
    botConfig.value = { blindBox: { revealMode: 'disclose' } };
    const body = await getState(conv(false));
    expect(body.reveal_mode).toBe('disclose');
    expect(body.model_revealed).toBe(false);
  });

  it('keeps model_revealed true once the conversation really was revealed', async () => {
    botConfig.value = { blindBox: { revealMode: 'disclose' } };
    expect((await getState(conv(true))).model_revealed).toBe(true);
  });

  it('passes surprise-mode reveal state straight through', async () => {
    botConfig.value = { blindBox: { revealMode: 'surprise' } };
    expect((await getState(conv(false))).model_revealed).toBe(false);
    expect((await getState(conv(true))).model_revealed).toBe(true);
  });

  it('still ships the drawn model slug while unrevealed (blind box is client-side only)', async () => {
    // Deliberate, not an oversight: the blind box is a toy with no reward
    // attached (author's call, 2026-08-20), so a packet-sniffing "cheat" wins
    // nothing. See the 🟡 entry in docs/tech-debt.md.
    botConfig.value = { blindBox: { revealMode: 'surprise' } };
    const body = await getState(conv(false));
    expect(body.model_revealed).toBe(false);
    expect(body.current_model_slug).toBe('anthropic/claude-x');
  });
});
