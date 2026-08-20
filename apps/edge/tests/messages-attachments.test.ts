import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<{
    Bindings: { SUPABASE_URL: string; SUPABASE_JWT_SECRET: string };
    Variables: { userId?: string; userJwt?: string };
  }> => async (c, next) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', u);
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

vi.mock('../src/lib/bot-reply', () => ({ runChatTurn: vi.fn() }));
vi.mock('../src/lib/memory', () => ({ maybeRefreshMemory: vi.fn() }));
vi.mock('../src/lib/lookback-runner', () => ({ runLookback: vi.fn() }));
vi.mock('../src/lib/title-runner', () => ({ runTitle: vi.fn() }));
vi.mock('../src/lib/billing', () => ({
  requireBalance: vi.fn(),
  InsufficientBalanceError: class {},
}));
vi.mock('../src/lib/group-mentions', () => ({ resolveGroupMentions: vi.fn(async () => []) }));
vi.mock('../src/lib/push', () => ({
  notifyConversationUsers: vi.fn(async () => undefined),
  notifyUserMessage: vi.fn(async () => undefined),
}));
vi.mock('../src/llm/vision', () => ({
  summarizeAttachments: vi.fn(async () => undefined),
  DEFAULT_VISION_MODEL: 'stub',
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let messageRoutes: any;

beforeEach(async () => {
  vi.resetModules();
  ({ messageRoutes } = await import('../src/routes/messages'));
});

describe('POST /v1/messages attachments', () => {
  it('accepts a group attachment-only message when the client sends an empty caption', async () => {
    const db = makeFakeDb({
      conversations: [
        {
          id: '11111111-1111-7111-8111-111111111111',
          conversation_type: 'group',
          bot_id: null,
          user_id: null,
          round_count: null,
        },
      ],
      attachments: [
        {
          id: '22222222-2222-7222-8222-222222222222',
          user_id: 'alice',
          conversation_id: '11111111-1111-7111-8111-111111111111',
          mime_type: 'image/jpeg',
          filename: 'photo.jpg',
        },
      ],
    });
    const app = new Hono<AppBindings>();
    app.route('/v1/messages', messageRoutes);
    const res = await app.request(
      '/v1/messages',
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-test-user-id': 'alice',
        },
        body: JSON.stringify({
          conversationId: '11111111-1111-7111-8111-111111111111',
          clientMessageId: '33333333-3333-7333-8333-333333333333',
          newMessage: '',
          attachmentIds: ['22222222-2222-7222-8222-222222222222'],
        }),
      },
      envWith(db),
      {
        waitUntil: () => undefined,
        passThroughOnException: () => undefined,
        props: {},
      },
    );
    const body = await res.json();
    expect(res.status).toBe(200);
    expect(body).toMatchObject({
      message: { id: expect.any(String) },
      botReplyScheduled: 'async',
    });
  });
});

function envWith(seed: FakeDb) {
  const fakeEnv = makeFakeEnv(seed);
  const memory = new Map<string, string>();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (fakeEnv as any).MEMORY = {
    get: async (key: string, type?: 'json') => {
      const value = memory.get(key);
      if (value == null) return null;
      return type === 'json' ? JSON.parse(value) : value;
    },
    put: async (key: string, value: string) => {
      memory.set(key, value);
    },
    delete: async (key: string) => {
      memory.delete(key);
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (fakeEnv as any).GROUP_ROUTER = {
    idFromName: (name: string) => name,
    get: () => ({ fetch: async () => new Response(null, { status: 204 }) }),
  };
  return fakeEnv;
}
