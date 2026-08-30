import { describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import { readFileSync } from 'node:fs';
import type { AppBindings } from '../src/types';
import {
  createConversationMessageRoutes,
  createMessageSearchRoutes,
  decodeMessageSearchCursor,
  tokenizeMessageSearchQuery,
  type MessageSearchStore,
} from '../src/routes/message-search';

vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<AppBindings> => async (c, next) => {
    const userId = c.req.header('x-test-user-id');
    if (!userId) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', userId);
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

const conversationId = '11111111-1111-4111-8111-111111111111';
const messageId = '22222222-2222-4222-8222-222222222222';

function makeStore(overrides: Partial<MessageSearchStore> = {}): MessageSearchStore {
  return {
    authorizeConversation: vi.fn(async () => true),
    search: vi.fn(async () => []),
    loadContext: vi.fn(async () => []),
    ...overrides,
  };
}

function appFor(store: MessageSearchStore): Hono<AppBindings> {
  const app = new Hono<AppBindings>();
  app.route('/v1/messages', createMessageSearchRoutes(store));
  app.route('/v1/conversations', createConversationMessageRoutes(store));
  return app;
}

describe('message search contract', () => {
  it('splits Unicode whitespace and folds case, accents, and full-width text', () => {
    expect(tokenizeMessageSearchQuery('  Caf\u00e9\u3000\u4e2d\u6587\t\uff21\uff22\uff23  ')).toEqual([
      'cafe',
      '\u4e2d\u6587',
      'abc',
    ]);
  });

  it('requires participant authorization for current-conversation search', async () => {
    const search = vi.fn(async () => []);
    const store = makeStore({
      authorizeConversation: vi.fn(async () => false),
      search,
    });
    const res = await appFor(store).request(
      `/v1/messages/search?scope=current&conversation_id=${conversationId}&query=hello`,
      { headers: { 'x-test-user-id': 'alice' } },
    );

    expect(res.status).toBe(403);
    expect(search).not.toHaveBeenCalled();
  });

  it('passes inclusive time bounds, clamps limit, and maps the fixed result shape', async () => {
    const search = vi.fn(async (_env, input) => [{
      conversation_id: conversationId,
      conversation_title: '\u6d4b\u8bd5\u4f1a\u8bdd',
      conversation_type: 'group',
      message_id: messageId,
      message_seq: 42,
      text: '\u4f60\u597d world',
      sender_name: 'Alice',
      sender_id: 'alice-id',
      created_at: '2026-08-30T01:02:03.000Z',
      attachment_metadata: [{ id: 'att-1', filename: '\u62a5\u544a.pdf', mimeType: 'application/pdf' }],
      matched_fields: ['text', 'sender'],
    }]);
    const store = makeStore({ search });
    const after = '2026-08-01T00:00:00Z';
    const before = '2026-08-31T00:00:00Z';
    const res = await appFor(store).request(
      `/v1/messages/search?scope=global&query=Alice%20world&after=${after}&before=${before}&limit=999`,
      { headers: { 'x-test-user-id': 'alice' } },
    );
    const body = await res.json() as { results: unknown[]; nextCursor: string };

    expect(res.status).toBe(200);
    expect(search).toHaveBeenCalledWith(undefined, {
      userId: 'alice',
      tokens: ['alice', 'world'],
      conversationId: null,
      after,
      before,
      cursor: null,
      fetchLimit: 201,
    });
    expect(body).toEqual({
      results: [{
        conversationId,
        conversationTitle: '\u6d4b\u8bd5\u4f1a\u8bdd',
        conversationType: 'group',
        messageId,
        messageSeq: 42,
        text: '\u4f60\u597d world',
        senderName: 'Alice',
        senderId: 'alice-id',
        createdAt: '2026-08-30T01:02:03.000Z',
        attachmentMetadata: [{ id: 'att-1', filename: '\u62a5\u544a.pdf', mimeType: 'application/pdf' }],
        matchedFields: ['text', 'sender'],
      }],
      nextCursor: null,
    });
  });

  it('rejects invalid or reversed ISO8601 bounds', async () => {
    const store = makeStore();
    const invalid = await appFor(store).request(
      '/v1/messages/search?query=x&after=not-a-date',
      { headers: { 'x-test-user-id': 'alice' } },
    );
    const reversed = await appFor(store).request(
      '/v1/messages/search?query=x&after=2026-08-31T00:00:00Z&before=2026-08-01T00:00:00Z',
      { headers: { 'x-test-user-id': 'alice' } },
    );

    expect(invalid.status).toBe(400);
    expect(reversed.status).toBe(400);
  });

  it('emits a stable newest-first cursor without skipping the extra row', async () => {
    const rows = [1, 2, 3].map((seq) => ({
      conversation_id: conversationId,
      conversation_title: 'Conversation',
      conversation_type: 'user_bot',
      message_id: `00000000-0000-4000-8000-00000000000${seq}`,
      message_seq: seq,
      text: `message ${seq}`,
      sender_name: 'Bot',
      sender_id: 'bot-id',
      created_at: `2026-08-30T01:02:0${4 - seq}.000Z`,
      attachment_metadata: [],
      matched_fields: ['text'],
    }));
    const store = makeStore({ search: vi.fn(async () => rows) });
    const res = await appFor(store).request(
      '/v1/messages/search?query=message&limit=2',
      { headers: { 'x-test-user-id': 'alice' } },
    );
    const body = await res.json() as { results: unknown[]; nextCursor: string };

    expect(body.results).toHaveLength(2);
    expect(decodeMessageSearchCursor(body.nextCursor)).toEqual({
      createdAt: rows[1].created_at,
      messageId: rows[1].message_id,
    });
  });
});

describe('around-message endpoint', () => {
  it('loads the requested old-message window after participant auth', async () => {
    const loadContext = vi.fn(async () => [{ id: messageId, message_seq: 42 }]);
    const store = makeStore({ loadContext });
    const res = await appFor(store).request(
      `/v1/conversations/${conversationId}/messages?around_seq=42&before=500&after=-1`,
      { headers: { 'x-test-user-id': 'alice' } },
    );
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(loadContext).toHaveBeenCalledWith(undefined, {
      userJwt: 'test-jwt',
      conversationId,
      aroundSeq: 42,
      before: 100,
      after: 0,
    });
    expect(body).toEqual({ rows: [{ id: messageId, message_seq: 42 }] });
  });

  it('does not disclose context for an unauthorized conversation', async () => {
    const loadContext = vi.fn(async () => []);
    const store = makeStore({
      authorizeConversation: vi.fn(async () => false),
      loadContext,
    });
    const res = await appFor(store).request(
      `/v1/conversations/${conversationId}/messages?around_seq=42`,
      { headers: { 'x-test-user-id': 'alice' } },
    );

    expect(res.status).toBe(403);
    expect(loadContext).not.toHaveBeenCalled();
  });

  it('returns not found when the requested message sequence is absent', async () => {
    const store = makeStore({ loadContext: vi.fn(async () => null) });
    const res = await appFor(store).request(
      `/v1/conversations/${conversationId}/messages?around_seq=42`,
      { headers: { 'x-test-user-id': 'alice' } },
    );

    expect(res.status).toBe(404);
  });
});

describe('message search migration guardrails', () => {
  const migration = readFileSync(
    new URL('../../../supabase/migrations/20260830013508_message_search.sql', import.meta.url),
    'utf8',
  );

  it('keeps the RPC service-role-only and checks both participant models', () => {
    expect(migration).toContain('security invoker');
    expect(migration).toMatch(/revoke execute on function pendingbot\.search_messages_for_user[\s\S]*from public, anon, authenticated/);
    expect(migration).toMatch(/grant execute on function pendingbot\.search_messages_for_user[\s\S]*to service_role/);
    expect(migration).toContain('pendingbot.conversation_participants');
    expect(migration).toContain('pendingbot.can_view_temporary_group');
  });

  it('searches only contract fields with inclusive bounds and stable keyset order', () => {
    expect(migration).toContain("coalesce(m.content, '') as text");
    expect(migration).toContain("a.filename, a.mime_type");
    expect(migration).toContain("to_char(m.created_at at time zone 'UTC'");
    expect(migration).not.toContain('a.r2_key');
    expect(migration).not.toContain('a.summary');
    expect(migration).not.toContain('conversation_title_haystack');
    expect(migration).toContain('m.created_at >= p_after');
    expect(migration).toContain('m.created_at <= p_before');
    expect(migration).toContain('(m.created_at, m.id) < (p_cursor_created_at, p_cursor_message_id)');
    expect(migration).toContain('order by matched.created_at desc, matched.message_id desc');
  });
});
