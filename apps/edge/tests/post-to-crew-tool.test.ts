// Tests for the bot-side `post_to_crew` tool
// (apps/edge/src/lib/bot-reply/tools/post-to-crew.ts).
//
// Phase 2 parity with the HTTP endpoint: a captain/master bot can @ a peer
// session / human and reply_to a prior message (auto-@ its sender). We pin the
// announcement RPC recipient args + mailbox enqueues + the mirror message's
// in_reply_to linkage, reusing the in-memory fake-supabase harness.

import { beforeEach, describe, expect, it } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import type { Env } from '../src/types';
import type { ToolCtx } from '../src/lib/bot-reply/tool-runner';

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let postToCrewTool: any;

beforeEach(async () => {
  ({ postToCrewTool } = await import('../src/lib/bot-reply/tools/post-to-crew'));
});

const USER = 'user-1';
const SUBJECT = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const CREW_ID = '33333333-3333-4333-8333-cccccccccccc';
const SESSION_B = '55555555-5555-4555-8555-eeeeeeeeeeee';
const BOT_ID = '66666666-6666-4666-8666-ffffffffffff';
const ANNOUNCEMENT_ID = '88888888-8888-4888-8888-000000000002';

function makeCtx(): { ctx: ToolCtx; emitted: Array<{ event: string; data: unknown }> } {
  const emitted: Array<{ event: string; data: unknown }> = [];
  const ctx = {
    emit: (event: string, data: unknown) => emitted.push({ event, data }),
    userId: USER,
    botId: BOT_ID,
    conversationId: CREW_ID,
  } as unknown as ToolCtx;
  return { ctx, emitted };
}

// Seed an active crew + capture the announcement RPC args and every mailbox
// enqueue, so each test can assert recipient targeting.
function seedCrew(db: FakeDb): {
  annArgs: Record<string, unknown>[];
  enqueues: Record<string, unknown>[];
} {
  db.rows.temporary_group_meta = [
    {
      conversation_id: CREW_ID,
      responsible_subject_id: SUBJECT,
      status: 'active',
      temporary_kind: 'crew',
    },
  ];
  const annArgs: Record<string, unknown>[] = [];
  const enqueues: Record<string, unknown>[] = [];
  db.rpcs = {
    create_crew_announcement_for_subject: (args) => {
      annArgs.push(args);
      return { data: ANNOUNCEMENT_ID, error: null };
    },
    enqueue_session_mailbox: (args) => {
      enqueues.push(args);
      return { data: crypto.randomUUID(), error: null };
    },
  };
  return { annArgs, enqueues };
}

describe('postToCrewTool — mentions + reply_to (Phase 2)', () => {
  it('@session B → recipient_session_ids includes B + B mailbox +1', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = seedCrew(db);
    const { ctx } = makeCtx();
    const out = JSON.parse(
      await postToCrewTool(
        makeFakeEnv(db) as Env,
        { content: '@B 接力', mentions: [{ kind: 'session', target_id: SESSION_B }] },
        ctx,
      ),
    );
    expect(out.ok).toBe(true);
    expect(annArgs[0].p_recipient_session_ids).toEqual([SESSION_B]);
    expect(enqueues.filter((e) => e.p_session_id === SESSION_B).length).toBe(1);
  });

  it('reply_to a session post → original sender auto-@d + in_reply_to on mirror', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = seedCrew(db);
    const REPLIED = '11111111-2222-4333-8444-555555555555';
    db.rows.messages = [
      {
        id: REPLIED,
        conversation_id: CREW_ID,
        role: 'log',
        log_kind: 'session_post',
        log_payload: { session_id: SESSION_B, text: '我开了头' },
        content: '我开了头',
        status: 'done',
        created_at: '2026-06-11T00:00:01Z',
      },
    ];
    const { ctx } = makeCtx();
    const out = JSON.parse(
      await postToCrewTool(makeFakeEnv(db) as Env, { content: '接着干', reply_to: REPLIED }, ctx),
    );
    expect(out.ok).toBe(true);
    expect(annArgs[0].p_recipient_session_ids).toEqual([SESSION_B]);
    expect(enqueues.filter((e) => e.p_session_id === SESSION_B).length).toBe(1);

    const mirror = db.inserts.find((i) => i.table === 'messages' && i.row.role === 'bot');
    expect((mirror?.row.log_payload as Record<string, unknown>).in_reply_to).toBe(REPLIED);
  });

  it('reply_to a human message → human member recipient, no mailbox', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = seedCrew(db);
    const REPLIED = '22222222-3333-4444-8555-666666666666';
    const HUMAN_MEMBER = 'mem-human-x';
    db.rows.messages = [
      {
        id: REPLIED,
        conversation_id: CREW_ID,
        role: 'user',
        user_id: USER,
        log_kind: null,
        log_payload: null,
        content: '帮我看看',
        status: 'done',
        created_at: '2026-06-11T00:00:01Z',
      },
    ];
    db.rows.temporary_group_members = [
      { id: HUMAN_MEMBER, conversation_id: CREW_ID, member_kind: 'human', user_id: USER, status: 'active' },
    ];
    const { ctx } = makeCtx();
    const out = JSON.parse(
      await postToCrewTool(makeFakeEnv(db) as Env, { content: '看完了', reply_to: REPLIED }, ctx),
    );
    expect(out.ok).toBe(true);
    expect(annArgs[0].p_recipient_member_ids).toEqual([HUMAN_MEMBER]);
    expect(annArgs[0].p_recipient_session_ids).toEqual([]);
    expect(enqueues.length).toBe(0);
  });

  it('no mentions + no reply_to → broadcast preserved (empty recipients)', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = seedCrew(db);
    const { ctx } = makeCtx();
    const out = JSON.parse(
      await postToCrewTool(makeFakeEnv(db) as Env, { content: 'milestone', category: 'milestone' }, ctx),
    );
    expect(out.ok).toBe(true);
    expect(annArgs[0].p_recipient_session_ids).toEqual([]);
    expect(annArgs[0].p_recipient_member_ids).toEqual([]);
    expect(enqueues.length).toBe(0);
  });

  it('reply_to non-existent message → error envelope, no announcement', async () => {
    const db = makeFakeDb();
    const { annArgs } = seedCrew(db);
    const MISSING = '33333333-4444-4555-8666-777777777777';
    const { ctx } = makeCtx();
    const out = JSON.parse(
      await postToCrewTool(makeFakeEnv(db) as Env, { content: 'x', reply_to: MISSING }, ctx),
    );
    expect(out.error).toBeTruthy();
    expect(annArgs.length).toBe(0);
  });
});
