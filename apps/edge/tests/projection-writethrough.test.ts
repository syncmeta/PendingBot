// 边缘自推投影(lib/projection-writethrough.ts)—— 「会话列表投影永远补不全」
// 的根治面。
//
// 线上事实(2026-08-19 实查 information_schema.triggers):`conversations` 从来
// 没有过 realtime_notify 触发器,`user_unread_counts` 的触发器在 2026-05-29 被
// 主动删掉。也就是说会话列表投影的标题 / bot / 预览 / 最后活跃时间**没有任何
// 数据库通知会送达**,只剩 participants 那一条通道 —— 它以前写的是一行
// `type:'unknown'` 的占位行,等一个永远不来的"随后补全"。
//
// 这里用真的 DO(node:sqlite 背 storage.sql)+ 假 Supabase 跑真实写穿链路,
// 覆盖:
//   - 参与者加入 → 补读会话行落**完整**一行,不再有 `unknown` 占位行
//   - 会话行读不到 → **什么都不写** + 留下可告警的失败日志
//   - runTitle 写完标题 → 投影里就是新标题(本次修复的核心用例)
//   - patch 落在缺行上 → 自动回落完整 sync 补齐,而不是造半成品
//   - 未读/预览/最后活跃时间的写穿,且不被后续会话级写穿冲掉

import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import { makeSqliteDoState } from './_helpers/do-sqlite';
import type { Env } from '../src/types';
import type { UserListResult } from '../src/durable-objects/user-projection';

installFakeSupabaseMock();

const alice = '11111111-1111-4111-8111-111111111111';
const bob = '22222222-2222-4222-8222-222222222222';
const convId = '33333333-3333-4333-8333-333333333333';
const botId = '44444444-4444-4444-8444-444444444444';

/**
 * 把真的 ConvProjectionDO / UserProjectionDO 挂进 env 的 DO namespace。
 * idFromName → 实例名,get(name) → 一个只有 fetch 的 stub,直接调 DO 的 fetch。
 */
async function makeProjectionEnv(db: FakeDb, warm: string[] = [alice]): Promise<Env> {
  const { ConvProjectionDO } = await import('../src/durable-objects/conv-projection');
  const { UserProjectionDO } = await import('../src/durable-objects/user-projection');
  const env = makeFakeEnv(db);

  const convs = new Map<string, InstanceType<typeof ConvProjectionDO>>();
  const users = new Map<string, InstanceType<typeof UserProjectionDO>>();

  const bind = <T extends { fetch(r: Request): Promise<Response> }>(
    cache: Map<string, T>,
    make: (name: string) => T,
  ) => ({
    idFromName: (name: string) => name,
    get: (name: string) => ({
      fetch: (url: string | URL, init?: RequestInit) => {
        let inst = cache.get(name);
        if (!inst) {
          inst = make(name);
          cache.set(name, inst);
        }
        return inst.fetch(new Request(String(url), init));
      },
    }),
  });

  const e = env as unknown as Record<string, unknown>;
  e.CONV_PROJECTION = bind(convs, (n) => new ConvProjectionDO(makeSqliteDoState(n), env));
  e.USER_PROJECTION = bind(users, (n) => new UserProjectionDO(makeSqliteDoState(n), env));

  // 预热 = 模拟"客户端已经拉过一次会话列表",让 UserProjectionDO 走过冷启动
  // 回填(backfilled=1)。不预热的话第一次 /list 会清空重建,把写穿刚落的行
  // 一起冲掉 —— 那是冷启动语义,不是本文件要测的写穿语义。
  for (const u of warm) await listFor(env, u);
  return env;
}

/** 读某用户的会话列表投影(全量)。 */
async function listFor(env: Env, userId: string): Promise<UserListResult> {
  const res = await env.USER_PROJECTION.get(
    env.USER_PROJECTION.idFromName(userId) as unknown as DurableObjectId,
  ).fetch('https://user-projection.do/list', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{}',
  });
  return (await res.json()) as UserListResult;
}

/** 一条已经建好的会话 + alice 的参与行(冷启动回填也吃这份数据)。 */
function seedDb(overrides?: { title?: string | null }): FakeDb {
  return makeFakeDb({
    conversations: [
      {
        id: convId,
        conversation_type: 'user_bot',
        user_id: alice,
        bot_id: botId,
        feature: null,
        round_count: 0,
        title: overrides?.title === undefined ? '打招呼' : overrides.title,
        updated_at: '2026-08-19T02:00:00+00:00',
      },
    ],
    conversation_participants: [
      { conversation_id: convId, participant_type: 'user', participant_id: alice },
    ],
    messages: [],
    user_unread_counts: [],
  });
}

/** 模拟一条 conversation_participants 的 INSERT webhook。 */
async function joinWebhook(env: Env, userId = alice) {
  const { projectWebhookRow } = await import('../src/lib/projection-writethrough');
  await projectWebhookRow(env, 'conversation_participants', 'insert', {
    conversation_id: convId,
    participant_type: 'user',
    participant_id: userId,
    joined_at: '2026-08-19T01:00:00+00:00',
  });
}

describe('participant join —— 不再写 unknown 占位行', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('补读会话行,落进去的是完整的一行(类型/bot/标题/时间戳全有)', async () => {
    const env = await makeProjectionEnv(seedDb());
    await joinWebhook(env);

    const list = await listFor(env, alice);
    expect(list.rows).toHaveLength(1);
    const row = list.rows[0]!;
    expect(row.type).toBe('user_bot');
    expect(row.bot_id).toBe(botId);
    expect(row.user_id).toBe(alice);
    expect(row.title).toBe('打招呼');
    // 时间戳是会话的 updated_at,不是"加入会话那一刻"。
    expect(row.updated_at).toBe('2026-08-19T02:00:00+00:00');
  });

  it('会话行读不到 → 一行都不写,并留下可告警的失败日志', async () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    // conversations 表里没有这条会话(只有参与行)。
    const db = makeFakeDb({
      conversations: [],
      conversation_participants: [
        { conversation_id: convId, participant_type: 'user', participant_id: alice },
      ],
      messages: [],
    });
    const env = await makeProjectionEnv(db);
    await joinWebhook(env);

    const list = await listFor(env, alice);
    // 宁可这条会话暂时不在列表里,也不留一行永远等不到补全的占位行。
    expect(list.rows).toHaveLength(0);
    const marker = err.mock.calls.map((c) => String(c[0]));
    expect(marker).toContain('[projection][write-through-failed]');
  });

  it('退出会话 → 从列表移除', async () => {
    const env = await makeProjectionEnv(seedDb());
    await joinWebhook(env);
    const { projectWebhookRow } = await import('../src/lib/projection-writethrough');
    await projectWebhookRow(env, 'conversation_participants', 'delete', {
      conversation_id: convId,
      participant_type: 'user',
      participant_id: alice,
    });
    expect((await listFor(env, alice)).rows).toHaveLength(0);
  });
});

describe('会话级 patch 写穿', () => {
  it('起标题写完 → 投影里就是新标题', async () => {
    const env = await makeProjectionEnv(seedDb({ title: null }));
    await joinWebhook(env);
    expect((await listFor(env, alice)).rows[0]!.title).toBeNull();

    const { patchConversationProjection } = await import(
      '../src/lib/projection-writethrough'
    );
    await patchConversationProjection(env, convId, {
      title: '打招呼',
      updated_at: '2026-08-19T03:00:00.000Z',
    });

    const row = (await listFor(env, alice)).rows[0]!;
    expect(row.title).toBe('打招呼');
    expect(row.updated_at).toBe('2026-08-19T03:00:00.000Z');
    // patch 只盖给出的列 —— 别的标量列不能被冲成 NULL。
    expect(row.bot_id).toBe(botId);
    expect(row.type).toBe('user_bot');
  });

  it('patch 落在缺行上 → 回落完整 sync 补齐,而不是造半成品', async () => {
    const env = await makeProjectionEnv(seedDb({ title: null }));
    // 没有跑 join webhook:conv DO 的 roster 由 /members 冷回填从 DB 拿到,
    // 但 alice 的列表投影里还没有这条会话行。
    const { patchConversationProjection } = await import(
      '../src/lib/projection-writethrough'
    );
    await patchConversationProjection(env, convId, { title: '打招呼' });

    const rows = (await listFor(env, alice)).rows;
    expect(rows).toHaveLength(1);
    // 回落 sync 走的是数据库那一行(title 仍是 null),但类型/bot 是全的 ——
    // 关键是它**不是**一行 unknown 占位。
    expect(rows[0]!.type).toBe('user_bot');
    expect(rows[0]!.bot_id).toBe(botId);
  });

  it('时间戳单调不回退(乱序到达不让"最后活跃"倒流)', async () => {
    const env = await makeProjectionEnv(seedDb());
    await joinWebhook(env);
    const { patchConversationProjection } = await import(
      '../src/lib/projection-writethrough'
    );
    await patchConversationProjection(env, convId, {
      updated_at: '2026-08-19T05:00:00.000Z',
    });
    await patchConversationProjection(env, convId, {
      updated_at: '2026-08-19T04:00:00.000Z',
    });
    expect((await listFor(env, alice)).rows[0]!.updated_at).toBe('2026-08-19T05:00:00.000Z');
  });
});

describe('线上遗留的 unknown 占位行', () => {
  /** 手工造一行 2026-08-19 之前那种半成品(标题空、bot 空、type='unknown')。 */
  async function seedLegacyPlaceholder(env: Env) {
    await env.USER_PROJECTION.get(
      env.USER_PROJECTION.idFromName(alice) as unknown as DurableObjectId,
    ).fetch('https://user-projection.do/ingest-conversation', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        row: { conv_id: convId, type: 'unknown', updated_at: '2026-08-19T01:00:00+00:00' },
      }),
    });
  }

  it('下一次会话级写穿会把它换成完整的一行(自愈)', async () => {
    const env = await makeProjectionEnv(seedDb());
    await seedLegacyPlaceholder(env);
    expect((await listFor(env, alice)).rows[0]!.type).toBe('unknown');

    const { patchConversationProjection } = await import(
      '../src/lib/projection-writethrough'
    );
    await patchConversationProjection(env, convId, { updated_at: '2026-08-19T07:00:00.000Z' });

    const row = (await listFor(env, alice)).rows[0]!;
    expect(row.type).toBe('user_bot');
    expect(row.bot_id).toBe(botId);
    expect(row.title).toBe('打招呼');
  });

  it('下一次未读写穿也会把它换掉', async () => {
    const env = await makeProjectionEnv(seedDb());
    await seedLegacyPlaceholder(env);

    const { projectUnreadRow } = await import('../src/lib/projection-writethrough');
    await projectUnreadRow(env, {
      user_id: alice,
      conversation_id: convId,
      unread_count: 1,
      last_message_preview: '你好呀',
      last_message_at: '2026-08-19T06:00:00+00:00',
    });

    const row = (await listFor(env, alice)).rows[0]!;
    expect(row.type).toBe('user_bot');
    expect(row.title).toBe('打招呼');
    expect(row.unread).toBe(1);
    expect(row.last_msg_preview).toBe('你好呀');
  });
});

describe('未读 / 预览 写穿', () => {
  it('未读行 → 列表拿到未读数、预览和最后活跃时间', async () => {
    const env = await makeProjectionEnv(seedDb());
    await joinWebhook(env);

    const { projectUnreadRow } = await import('../src/lib/projection-writethrough');
    await projectUnreadRow(env, {
      user_id: alice,
      conversation_id: convId,
      unread_count: 3,
      last_message_preview: '你好呀',
      last_message_at: '2026-08-19T06:00:00+00:00',
    });

    const row = (await listFor(env, alice)).rows[0]!;
    expect(row.unread).toBe(3);
    expect(row.last_msg_preview).toBe('你好呀');
    expect(row.updated_at).toBe('2026-08-19T06:00:00+00:00');
  });

  it('随后的会话级写穿不会把预览清空', async () => {
    const env = await makeProjectionEnv(seedDb());
    await joinWebhook(env);
    const { projectUnreadRow, patchConversationProjection, syncConversationProjection } =
      await import('../src/lib/projection-writethrough');

    await projectUnreadRow(env, {
      user_id: alice,
      conversation_id: convId,
      unread_count: 2,
      last_message_preview: '你好呀',
      last_message_at: '2026-08-19T06:00:00+00:00',
    });
    await patchConversationProjection(env, convId, { title: '新标题' });
    await syncConversationProjection(env, convId);

    const row = (await listFor(env, alice)).rows[0]!;
    expect(row.last_msg_preview).toBe('你好呀');
    expect(row.unread).toBe(2);
  });

  it('未读行落在缺行上 → 补齐会话行后未读/预览仍然落上去', async () => {
    const env = await makeProjectionEnv(seedDb());
    // 没跑 join webhook,alice 的投影里还没有这条会话。
    const { projectUnreadRow } = await import('../src/lib/projection-writethrough');
    await projectUnreadRow(env, {
      user_id: alice,
      conversation_id: convId,
      unread_count: 1,
      last_message_preview: '你好呀',
      last_message_at: '2026-08-19T06:00:00+00:00',
    });

    const rows = (await listFor(env, alice)).rows;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.type).toBe('user_bot');
    expect(rows[0]!.unread).toBe(1);
    expect(rows[0]!.last_msg_preview).toBe('你好呀');
  });

  it('群会话:每个成员的列表都被喂到', async () => {
    const db = seedDb();
    db.rows.conversations![0]!.conversation_type = 'group';
    db.rows.conversations![0]!.bot_id = null;
    db.rows.conversation_participants!.push({
      conversation_id: convId,
      participant_type: 'user',
      participant_id: bob,
    });
    const env = await makeProjectionEnv(db, [alice, bob]);
    await joinWebhook(env, alice);
    await joinWebhook(env, bob);

    const { patchConversationProjection } = await import(
      '../src/lib/projection-writethrough'
    );
    await patchConversationProjection(env, convId, { title: '群名' });

    expect((await listFor(env, alice)).rows[0]!.title).toBe('群名');
    expect((await listFor(env, bob)).rows[0]!.title).toBe('群名');
  });
});
