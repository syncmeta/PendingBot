// E5 — vitest for the T2 edge read projection (conv message-tail + user list)
// and the message-tail authorization gate.
//
// The projection DOs (ConvProjectionDO / UserProjectionDO) are SQLite-backed
// via workerd's ctx.storage.sql. The repo's vitest runs in plain Node, so we
// back storage.sql with node:sqlite (see _helpers/do-sqlite.ts) — the DO's
// *real* SQL runs against a real engine, exercising the actual upsert / delta /
// tombstone / trim queries rather than a re-implementation.
//
// Coverage:
//   - delta:    getTail({sinceRev}) only returns rev>sinceRev; sinceRev>cur_rev
//               or epoch mismatch → full re-fetch.
//   - idempotency: ingesting the same message id twice keeps one row, rev bumps.
//   - tombstone: markDeleted → getTail returns the id in tombstones, not in rows.
//   - backfill:  a cold DO's first getTail/isMember triggers a Supabase rebuild.
//   - trim:      exceeding N_KEEP drops the oldest rows.
//   - rich cols: getTail round-trips the full message-self columns (citations /
//                metadata / log_payload / message_seq / parent / model_slug …).
//   - 2MB guard: an oversized metadata/log_payload row ingests under the limit,
//                the heaviest JSON column is truncated to the marker, the rest
//                survive intact, and a backfill carries the same rich columns.
//   - scalar cols: getList round-trips the scalar conversation columns
//                  (bot_id / user_id / feature / round_count); backfill too.
//   - auth gate: userB cannot read userA's tail (group non-member → 403;
//                single-owner non-owner → 403); member/owner → 200.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import { makeSqliteDoState } from './_helpers/do-sqlite';
import type { AppBindings } from '../src/types';

// requireSession stub — x-test-user-id header → userId/userJwt (same shape as
// the other route tests).
vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<{
    Bindings: Record<string, unknown>;
    Variables: { userId?: string; userJwt?: string };
  }> => async (c, next) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', u);
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

// conv-cache is mocked per-suite for the auth-gate tests (KV hot path +
// Supabase resolve). Default export: cold cache + deny-by-default resolve.
const getCachedConvMock = vi.fn();
const resolveConvMock = vi.fn();
vi.mock('../src/lib/conv-cache', () => ({
  getCachedConv: (...a: unknown[]) => getCachedConvMock(...a),
  resolveConv: (...a: unknown[]) => resolveConvMock(...a),
  // projections.ts imports the single-owner type set from here; keep the mock
  // in sync with the real set (its correctness is guarded by
  // tests/projection-rls-guard.test.ts).
  SINGLE_OWNER_TYPES: new Set([
    'user_bot',
    'self',
    'user_user',
    'discuss',
    'surf',
    'portrait',
  ]),
}));

installFakeSupabaseMock();

const alice = '11111111-1111-4111-8111-111111111111';
const bob = '22222222-2222-4222-8222-222222222222';
const convId = '33333333-3333-4333-8333-333333333333';

// ── DO unit tests ────────────────────────────────────────────────────

describe('ConvProjectionDO — delta / idempotency / tombstone / trim', () => {
  // Late import so the node:sqlite-backed state shim is available; the DO
  // class itself is pure (no workerd globals beyond storage.sql).
  async function newConv(name = convId) {
    const { ConvProjectionDO } = await import('../src/durable-objects/conv-projection');
    const env = makeFakeEnv(makeFakeDb());
    return new ConvProjectionDO(makeSqliteDoState(name), env);
  }

  function msg(id: string, createdAt: string, extra?: Record<string, unknown>) {
    return {
      id,
      created_at: createdAt,
      role: 'user',
      status: 'done',
      content: `c-${id}`,
      ...extra,
    };
  }

  it('ingestMessage is idempotent by id and bumps rev monotonically', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:00Z'));
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:00Z', { content: 'edited' }));

    const tail = conv.getTail();
    // one row, latest content, rev advanced past the first write.
    expect(tail.rows).toHaveLength(1);
    expect(tail.rows[0]!.id).toBe('m1');
    expect(tail.rows[0]!.content).toBe('edited');
    expect(tail.rows[0]!.rev).toBe(2);
    expect(tail.rev).toBe(2);
    expect(tail.full).toBe(false);
  });

  it('getTail({sinceRev}) returns only rows with rev > sinceRev', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:01Z')); // rev 1
    conv.ingestMessage(msg('m2', '2026-01-01T00:00:02Z')); // rev 2
    conv.ingestMessage(msg('m3', '2026-01-01T00:00:03Z')); // rev 3

    const delta = conv.getTail({ sinceRev: 2 });
    expect(delta.full).toBe(false);
    expect(delta.rows.map((r) => r.id)).toEqual(['m3']);
    expect(delta.rev).toBe(3);

    // sinceRev at the head → no new rows (the normal "nothing changed").
    expect(conv.getTail({ sinceRev: 3 }).rows).toHaveLength(0);
  });

  it('rows come back in ascending time order even though stored DESC', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:01Z'));
    conv.ingestMessage(msg('m2', '2026-01-01T00:00:02Z'));
    conv.ingestMessage(msg('m3', '2026-01-01T00:00:03Z'));
    expect(conv.getTail().rows.map((r) => r.id)).toEqual(['m1', 'm2', 'm3']);
  });

  it('sinceRev beyond cur_rev → full re-fetch (cursor from the future)', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:01Z')); // cur_rev 1
    const res = conv.getTail({ sinceRev: 99 });
    expect(res.full).toBe(true);
    // full ignores sinceRev and returns the whole tail.
    expect(res.rows.map((r) => r.id)).toEqual(['m1']);
    expect(res.tombstones).toEqual([]);
  });

  it('epoch mismatch → full re-fetch regardless of sinceRev', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:01Z'));
    conv.ingestMessage(msg('m2', '2026-01-01T00:00:02Z'));
    const res = conv.getTail({ sinceRev: 1, epoch: 'stale-epoch' });
    expect(res.full).toBe(true);
    expect(res.rows.map((r) => r.id)).toEqual(['m1', 'm2']);
  });

  it('markDeleted → tombstone id in delta, not in rows; no body leaked', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:01Z')); // rev 1
    conv.ingestMessage(msg('m2', '2026-01-01T00:00:02Z')); // rev 2
    conv.markDeleted('m1'); // rev 3, tombstone

    const delta = conv.getTail({ sinceRev: 1 });
    // m1 must not appear as a content row...
    expect(delta.rows.map((r) => r.id)).not.toContain('m1');
    // ...but its deletion must be reported.
    expect(delta.tombstones).toContain('m1');

    // a true full re-fetch (epoch mismatch) carries no tombstones — the live
    // set already excludes the deleted row, so there is nothing to "catch up".
    const full = conv.getTail({ sinceRev: 1, epoch: 'stale' });
    expect(full.full).toBe(true);
    expect(full.rows.map((r) => r.id)).toEqual(['m2']);
    expect(full.tombstones).toEqual([]);
  });

  it('trim drops the oldest rows once the row count exceeds N_KEEP', async () => {
    const { ConvProjectionDO, N_KEEP } = await import('../src/durable-objects/conv-projection');
    const env = makeFakeEnv(makeFakeDb());
    const conv = new ConvProjectionDO(makeSqliteDoState(convId), env);
    const keep = N_KEEP;
    // Ingest N_KEEP + 5; the 5 oldest should be trimmed away.
    for (let i = 0; i < keep + 5; i++) {
      const n = String(i).padStart(5, '0');
      conv.ingestMessage(msg(`m${n}`, `2026-01-01T00:00:${n}Z`));
    }
    const tail = conv.getTail({ limit: keep + 100 });
    expect(tail.rows).toHaveLength(keep);
    // The very oldest (m00000..m00004) are gone; the newest survive.
    expect(tail.rows[0]!.id).toBe('m00005');
    expect(tail.rows.at(-1)!.id).toBe(`m${String(keep + 4).padStart(5, '0')}`);
  });

  it('isMember: owner via meta or roster membership; non-member denied', async () => {
    const conv = await newConv();
    conv.setMeta({ owner_user_id: alice });
    expect(conv.isMember(alice)).toBe(true); // owner
    expect(conv.isMember(bob)).toBe(false); // neither owner nor roster

    conv.ingestRoster('add', bob);
    expect(conv.isMember(bob)).toBe(true); // now in roster
    conv.ingestRoster('remove', bob);
    expect(conv.isMember(bob)).toBe(false); // evicted
  });

  it('getTail round-trips the full rich message-self columns', async () => {
    const conv = await newConv();
    const citations = [{ url: 'https://a.example', title: 'A' }];
    const metadata = { source: 'web', tool_trace: [{ tool: 'search', ms: 42 }] };
    const logPayload = { kind: 'recall', target: 'm0' };
    const attachments = { ids: ['att-1', 'att-2'] };
    conv.ingestMessage(
      msg('m1', '2026-01-01T00:00:01Z', {
        client_message_id: 'cmid-1',
        message_seq: 7,
        log_kind: 'recall',
        log_payload: logPayload,
        bubble_group_id: 'bg-1',
        parent_message_id: 'p-1',
        model_slug: 'opus-4',
        sender_user_id: alice,
        sender_bot_id: null,
        attachments,
        citations,
        metadata,
      }),
    );

    const row = conv.getTail().rows[0]!;
    // scalar self-columns.
    expect(row.client_message_id).toBe('cmid-1');
    expect(row.message_seq).toBe(7);
    expect(row.log_kind).toBe('recall');
    expect(row.bubble_group_id).toBe('bg-1');
    expect(row.parent_message_id).toBe('p-1');
    expect(row.model_slug).toBe('opus-4');
    expect(row.sender_user_id).toBe(alice);
    expect(row.sender_bot_id).toBeNull();
    // JSON self-columns parsed back to structured values, not raw strings.
    expect(row.citations).toEqual(citations);
    expect(row.metadata).toEqual(metadata);
    expect(row.log_payload).toEqual(logPayload);
    expect(row.attachments).toEqual(attachments);
  });

  it('absent rich columns come back as null, not the string "undefined"', async () => {
    const conv = await newConv();
    conv.ingestMessage(msg('m1', '2026-01-01T00:00:01Z')); // bare: no rich cols
    const row = conv.getTail().rows[0]!;
    expect(row.client_message_id).toBeNull();
    expect(row.message_seq).toBeNull();
    expect(row.log_kind).toBeNull();
    expect(row.log_payload).toBeNull();
    expect(row.parent_message_id).toBeNull();
    expect(row.model_slug).toBeNull();
    expect(row.citations).toBeNull();
    expect(row.metadata).toBeNull();
    expect(row.attachments).toBeNull();
  });

  it('2MB guard: oversized metadata is truncated to the marker, other cols intact', async () => {
    const { ConvProjectionDO, TRUNCATED_MARKER } = await import(
      '../src/durable-objects/conv-projection'
    );
    const env = makeFakeEnv(makeFakeDb());
    const conv = new ConvProjectionDO(makeSqliteDoState(convId), env);

    // metadata is the single heaviest column (~1.8MB) → over the 1.5MB guard.
    const hugeMetadata = { blob: 'x'.repeat(1_800_000) };
    const citations = [{ url: 'https://keep.example' }]; // small → must survive
    conv.ingestMessage(
      msg('big', '2026-01-01T00:00:01Z', {
        metadata: hugeMetadata,
        citations,
        content: 'render-me',
      }),
    );

    const row = conv.getTail().rows[0]!;
    // heaviest JSON column replaced by the truncation marker...
    expect(row.metadata).toEqual(TRUNCATED_MARKER);
    // ...everything else preserved (content is never truncated; small JSON kept).
    expect(row.content).toBe('render-me');
    expect(row.citations).toEqual(citations);

    // and the stored row is genuinely under the 2MB DO hard cap.
    const storedBytes = new TextEncoder().encode(JSON.stringify(row)).length;
    expect(storedBytes).toBeLessThan(2_000_000);
  });

  it('2MB guard: only the heaviest cols are dropped, lighter ones below the line survive', async () => {
    const { ConvProjectionDO, TRUNCATED_MARKER } = await import(
      '../src/durable-objects/conv-projection'
    );
    const env = makeFakeEnv(makeFakeDb());
    const conv = new ConvProjectionDO(makeSqliteDoState(convId), env);

    // metadata huge, log_payload medium, citations tiny. Dropping metadata
    // alone gets us under the line → log_payload + citations should survive.
    const hugeMetadata = { blob: 'm'.repeat(1_700_000) };
    const mediumLog = { trace: 'l'.repeat(50_000) };
    const tinyCitations = [{ url: 'https://x.example' }];
    conv.ingestMessage(
      msg('big', '2026-01-01T00:00:01Z', {
        metadata: hugeMetadata,
        log_payload: mediumLog,
        citations: tinyCitations,
      }),
    );

    const row = conv.getTail().rows[0]!;
    expect(row.metadata).toEqual(TRUNCATED_MARKER); // heaviest dropped
    expect(row.log_payload).toEqual(mediumLog); // survived
    expect(row.citations).toEqual(tinyCitations); // survived
  });
});

describe('ConvProjectionDO — cold backfill from Supabase', () => {
  it('cold DO /tail backfills tail + roster + meta on first read', async () => {
    const { ConvProjectionDO } = await import('../src/durable-objects/conv-projection');
    const db: FakeDb = makeFakeDb({
      conversations: [{ id: convId, conversation_type: 'group', user_id: null }],
      conversation_participants: [
        { conversation_id: convId, participant_id: alice, participant_type: 'user' },
        { conversation_id: convId, participant_id: bob, participant_type: 'user' },
        // a bot participant must NOT enter the roster.
        { conversation_id: convId, participant_id: 'bot-x', participant_type: 'bot' },
      ],
      messages: [
        {
          id: 'b1',
          conversation_id: convId,
          created_at: '2026-01-01T00:00:01Z',
          message_seq: 1,
          role: 'user',
          status: 'done',
          content: 'hello',
          user_id: alice,
          client_message_id: 'cmid-b1',
          bubble_group_id: 'bg-b1',
          attachments: { ids: ['att-b1'] },
          metadata: null,
        },
        {
          id: 'b2',
          conversation_id: convId,
          created_at: '2026-01-01T00:00:02Z',
          message_seq: 2,
          role: 'assistant',
          status: 'done',
          content: 'hi back',
          user_id: null,
          model_slug: 'opus-4',
          parent_message_id: 'b1',
          citations: [{ url: 'https://cite.example' }],
          metadata: { source: 'web' },
        },
        // §7.2 deleted + voice_call_summary must be excluded from the rebuild.
        {
          id: 'b3-deleted',
          conversation_id: convId,
          created_at: '2026-01-01T00:00:03Z',
          message_seq: 3,
          role: 'user',
          status: 'deleted',
          content: 'oops',
          user_id: alice,
          metadata: null,
        },
        {
          id: 'b4-voice',
          conversation_id: convId,
          created_at: '2026-01-01T00:00:04Z',
          message_seq: 4,
          role: 'assistant',
          status: 'done',
          content: 'call summary',
          user_id: null,
          metadata: { source: 'voice_call_summary' },
        },
      ],
    });
    const env = makeFakeEnv(db);
    const conv = new ConvProjectionDO(makeSqliteDoState(convId), env);

    // Drive through the fetch RPC so ensureBackfilled() runs (matches the read
    // endpoint's entry path).
    const res = await conv.fetch(
      new Request('https://conv-projection.do/tail', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{}',
      }),
    );
    const tail = (await res.json()) as {
      rows: Array<{
        id: string;
        client_message_id: string | null;
        message_seq: number | null;
        bubble_group_id: string | null;
        parent_message_id: string | null;
        model_slug: string | null;
        attachments: unknown;
        citations: unknown;
        metadata: unknown;
      }>;
      tombstones: string[];
    };
    // only the two live, non-voice messages, in time order.
    expect(tail.rows.map((r) => r.id)).toEqual(['b1', 'b2']);

    // rich columns survive the cold rebuild (not just the render skeleton).
    const b1 = tail.rows.find((r) => r.id === 'b1')!;
    expect(b1.client_message_id).toBe('cmid-b1');
    expect(b1.message_seq).toBe(1);
    expect(b1.bubble_group_id).toBe('bg-b1');
    expect(b1.attachments).toEqual({ ids: ['att-b1'] });
    const b2 = tail.rows.find((r) => r.id === 'b2')!;
    expect(b2.model_slug).toBe('opus-4');
    expect(b2.parent_message_id).toBe('b1');
    expect(b2.citations).toEqual([{ url: 'https://cite.example' }]);
    expect(b2.metadata).toEqual({ source: 'web' });

    // roster only carries the two human participants.
    expect(conv.getRoster().sort()).toEqual([alice, bob].sort());
    // owner meta came from conversations.user_id (null here → group).
    expect(conv.getMeta().conv_type).toBe('group');

    // second read is served from the warm DO (backfilled=1) — no double rebuild.
    expect(conv.getMeta().backfilled).toBe('1');
  });
});

describe('UserProjectionDO — delta + cold backfill', () => {
  async function newUser(name = alice) {
    const { UserProjectionDO } = await import('../src/durable-objects/user-projection');
    const env = makeFakeEnv(makeFakeDb());
    return new UserProjectionDO(makeSqliteDoState(name), env);
  }

  it('getList delta: only rev>sinceRev rows; epoch mismatch → full', async () => {
    const user = await newUser();
    user.ingestConversation({ conv_id: 'c1', type: 'group', updated_at: '2026-01-01T00:00:01Z' }); // rev 1
    user.ingestConversation({ conv_id: 'c2', type: 'group', updated_at: '2026-01-01T00:00:02Z' }); // rev 2

    const delta = user.getList({ sinceRev: 1 });
    expect(delta.full).toBe(false);
    expect(delta.rows.map((r) => r.conv_id)).toEqual(['c2']);

    const stale = user.getList({ sinceRev: 1, epoch: 'nope' });
    expect(stale.full).toBe(true);
    expect(stale.rows.map((r) => r.conv_id).sort()).toEqual(['c1', 'c2']);
  });

  it('getList round-trips the scalar conversation columns', async () => {
    const user = await newUser();
    user.ingestConversation({
      conv_id: 'c1',
      type: 'user_bot',
      bot_id: 'bot-9',
      user_id: alice,
      feature: 'chat',
      round_count: 12,
      title: 'My bot',
      updated_at: '2026-01-01T00:00:01Z',
    });
    const row = user.getList().rows.find((r) => r.conv_id === 'c1')!;
    expect(row.bot_id).toBe('bot-9');
    expect(row.user_id).toBe(alice);
    expect(row.feature).toBe('chat');
    expect(row.round_count).toBe(12);
    expect(row.title).toBe('My bot');
  });

  it('scalar columns are preserved via COALESCE when a later upsert omits them', async () => {
    const user = await newUser();
    // first the conversations webhook lands the scalar columns...
    user.ingestConversation({
      conv_id: 'c1',
      type: 'user_bot',
      bot_id: 'bot-9',
      feature: 'chat',
      round_count: 3,
      updated_at: '2026-01-01T00:00:01Z',
    });
    // ...then a minimal participant-join upsert arrives without them. COALESCE
    // must keep the already-filled scalars rather than NULL them out.
    user.ingestConversation({ conv_id: 'c1', type: 'user_bot', updated_at: '2026-01-01T00:00:02Z' });
    const row = user.getList().rows.find((r) => r.conv_id === 'c1')!;
    expect(row.bot_id).toBe('bot-9');
    expect(row.feature).toBe('chat');
    expect(row.round_count).toBe(3);
    expect(row.updated_at).toBe('2026-01-01T00:00:02Z'); // updated_at always overwrites
  });

  it('ingestUnread ignores conversations not in the list; updates existing', async () => {
    const user = await newUser();
    user.ingestUnread('ghost', 5); // no such conv → no row created
    expect(user.getList().rows).toHaveLength(0);

    user.ingestConversation({ conv_id: 'c1', type: 'group', updated_at: '2026-01-01T00:00:01Z' });
    user.ingestUnread('c1', 3, 'preview');
    const row = user.getList().rows.find((r) => r.conv_id === 'c1')!;
    expect(row.unread).toBe(3);
    expect(row.last_msg_preview).toBe('preview');
  });

  it('cold /list backfills the conversation list from user_unread_counts', async () => {
    const { UserProjectionDO } = await import('../src/durable-objects/user-projection');
    const db: FakeDb = makeFakeDb({
      user_unread_counts: [
        {
          user_id: alice,
          conversation_id: 'c1',
          unread_count: 2,
          last_message_preview: 'yo',
          conv: {
            conversation_type: 'group',
            title: 'Team',
            bot_id: null,
            user_id: null,
            feature: null,
            round_count: 0,
            updated_at: '2026-01-02T00:00:00Z',
          },
        },
        {
          user_id: alice,
          conversation_id: 'c2',
          unread_count: 0,
          last_message_preview: null,
          conv: {
            conversation_type: 'user_bot',
            title: null,
            bot_id: 'bot-7',
            user_id: alice,
            feature: 'chat',
            round_count: 5,
            updated_at: '2026-01-01T00:00:00Z',
          },
        },
      ],
    });
    const env = makeFakeEnv(db);
    const user = new UserProjectionDO(makeSqliteDoState(alice), env);

    const res = await user.fetch(
      new Request('https://user-projection.do/list', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{}',
      }),
    );
    const list = (await res.json()) as {
      rows: Array<{
        conv_id: string;
        unread: number;
        title: string | null;
        bot_id: string | null;
        user_id: string | null;
        feature: string | null;
        round_count: number | null;
      }>;
      full: boolean;
    };
    // ordered by updated_at DESC → c1 (Jan 2) before c2 (Jan 1).
    expect(list.rows.map((r) => r.conv_id)).toEqual(['c1', 'c2']);
    expect(list.rows[0]!.unread).toBe(2);
    expect(list.rows[0]!.title).toBe('Team');
    // scalar columns survive the cold rebuild (not just title/preview skeleton).
    const c2 = list.rows.find((r) => r.conv_id === 'c2')!;
    expect(c2.bot_id).toBe('bot-7');
    expect(c2.user_id).toBe(alice);
    expect(c2.feature).toBe('chat');
    expect(c2.round_count).toBe(5);
    expect(user.getMeta().backfilled).toBe('1');
  });
});

// ── auth gate route tests ────────────────────────────────────────────

describe('GET /v1/messages/tail — authorization gate (fail-closed)', () => {
  let messageTailRoutes: unknown;

  // A fake CONV_PROJECTION binding whose /is-member and /tail answers are
  // driven per-test. /tail always returns a small non-empty tail so a 200
  // path is observable.
  function fakeConvBinding(opts: { members: Set<string> }) {
    return {
      idFromName: (n: string) => n,
      get: () => ({
        fetch: async (url: string | URL, init?: { body?: string }) => {
          const path = new URL(String(url)).pathname;
          const body = init?.body ? (JSON.parse(init.body) as Record<string, unknown>) : {};
          if (path === '/is-member') {
            return Response.json({ member: opts.members.has(String(body.userId)) });
          }
          if (path === '/tail') {
            return Response.json({
              epoch: 'e1',
              rev: 1,
              rows: [{ id: 'm1', created_at: '2026-01-01T00:00:01Z', rev: 1 }],
              tombstones: [],
              full: false,
            });
          }
          return Response.json({ error: 'not found' }, { status: 404 });
        },
      }),
    };
  }

  async function tailReq(env: ReturnType<typeof makeFakeEnv>, userId: string) {
    const app = new Hono<AppBindings>();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    app.route('/v1/messages', messageTailRoutes as any);
    const res = await app.request(
      `/v1/messages/tail?conv=${convId}`,
      { method: 'GET', headers: { 'x-test-user-id': userId } },
      env,
    );
    let json: Record<string, unknown> = {};
    try {
      json = (await res.json()) as Record<string, unknown>;
    } catch {
      /* empty */
    }
    return { status: res.status, body: json };
  }

  beforeEach(async () => {
    vi.clearAllMocks();
    ({ messageTailRoutes } = await import('../src/routes/projections'));
  });

  it('rejects a bad conv id with 400 invalid_query', async () => {
    const env = makeFakeEnv(makeFakeDb());
    (env as unknown as { CONV_PROJECTION: unknown }).CONV_PROJECTION = fakeConvBinding({
      members: new Set(),
    });
    const app = new Hono<AppBindings>();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    app.route('/v1/messages', messageTailRoutes as any);
    const res = await app.request(
      '/v1/messages/tail?conv=not-a-uuid',
      { method: 'GET', headers: { 'x-test-user-id': alice } },
      env,
    );
    const body = (await res.json()) as { error?: { code?: string } };
    expect(res.status).toBe(400);
    expect(body.error?.code).toBe('invalid_query');
  });

  it('single-owner: owner via KV hot path → 200', async () => {
    getCachedConvMock.mockResolvedValue({
      id: convId,
      conversation_type: 'user_bot',
      user_id: alice,
    });
    const env = makeFakeEnv(makeFakeDb());
    (env as unknown as { CONV_PROJECTION: unknown }).CONV_PROJECTION = fakeConvBinding({
      members: new Set(),
    });
    const { status, body } = await tailReq(env, alice);
    expect(status).toBe(200);
    expect(Array.isArray(body.rows)).toBe(true);
    // owner resolved off KV — never fell through to the Supabase resolve.
    expect(resolveConvMock).not.toHaveBeenCalled();
  });

  it('single-owner: non-owner KV mismatch, resolve denies → 403 forbidden', async () => {
    getCachedConvMock.mockResolvedValue({
      id: convId,
      conversation_type: 'user_bot',
      user_id: alice,
    });
    // KV said owner=alice; bob asks → falls through to resolveConv, which (RLS)
    // returns null = no access.
    resolveConvMock.mockResolvedValue(null);
    const env = makeFakeEnv(makeFakeDb());
    (env as unknown as { CONV_PROJECTION: unknown }).CONV_PROJECTION = fakeConvBinding({
      members: new Set(),
    });
    const { status, body } = await tailReq(env, bob);
    expect(status).toBe(403);
    expect((body.error as { code?: string }).code).toBe('forbidden');
  });

  it('group: roster member via edge isMember → 200', async () => {
    getCachedConvMock.mockResolvedValue({
      id: convId,
      conversation_type: 'group',
      user_id: null,
    });
    const env = makeFakeEnv(makeFakeDb());
    (env as unknown as { CONV_PROJECTION: unknown }).CONV_PROJECTION = fakeConvBinding({
      members: new Set([alice]),
    });
    const { status } = await tailReq(env, alice);
    expect(status).toBe(200);
    // membership settled at the edge → no Supabase resolve needed.
    expect(resolveConvMock).not.toHaveBeenCalled();
  });

  it('group: non-member (edge miss + resolve denies) → 403 forbidden', async () => {
    getCachedConvMock.mockResolvedValue({
      id: convId,
      conversation_type: 'group',
      user_id: null,
    });
    resolveConvMock.mockResolvedValue(null); // RLS says bob is not a participant
    const env = makeFakeEnv(makeFakeDb());
    (env as unknown as { CONV_PROJECTION: unknown }).CONV_PROJECTION = fakeConvBinding({
      members: new Set([alice]), // bob absent
    });
    const { status, body } = await tailReq(env, bob);
    expect(status).toBe(403);
    expect((body.error as { code?: string }).code).toBe('forbidden');
  });

  it('cold KV: resolveConv authorizes (group member) → 200', async () => {
    getCachedConvMock.mockResolvedValue(null); // KV cold
    resolveConvMock.mockResolvedValue({ conversation_type: 'group', user_id: null });
    const env = makeFakeEnv(makeFakeDb());
    (env as unknown as { CONV_PROJECTION: unknown }).CONV_PROJECTION = fakeConvBinding({
      members: new Set([alice]),
    });
    const { status } = await tailReq(env, alice);
    expect(status).toBe(200);
    expect(resolveConvMock).toHaveBeenCalledTimes(1);
  });
});
