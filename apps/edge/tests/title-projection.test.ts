// runTitle 端到端:起完标题,**边缘会话列表投影里就是新标题**。
//
// 这是「Mac/iPhone 会话列表一直显示『新对话』」那个 bug 的正面用例。
// conversations 表线上没有 realtime_notify 触发器(从来没建过),所以标题写进
// 数据库之后没有任何通知会把它送进读投影 —— runTitle 必须自己推。
//
// LLM 那一段(withFallback / prompt / model-role)全部替身;真正跑的是
// "写 conversations → patchConversationProjection → UserProjectionDO" 这条链路。

import { describe, expect, it, vi } from 'vitest';
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

vi.mock('../src/llm/prompt-loader', () => ({
  ensurePromptOverridesLoaded: async () => {},
  getPrompt: () => 'title-system-prompt',
}));
vi.mock('../src/lib/model-roles', () => ({
  getModelRole: async () => 'google/gemma-4-31b-it',
}));
vi.mock('../src/llm/router', () => ({
  FallbackError: class FallbackError extends Error {
    routeTrace: unknown[] = [];
    lastRoute = null;
  },
  usageFromCompletion: () => ({}),
  enqueueAudit: async () => {},
  withFallback: async () => ({
    result: { id: 'gen-1', choices: [{ message: { content: '「打招呼」' } }], usage: {} },
    route: null,
    routeTrace: [],
  }),
}));

const alice = '11111111-1111-4111-8111-111111111111';
const convId = '33333333-3333-4333-8333-333333333333';
const botId = '44444444-4444-4444-8444-444444444444';

async function makeEnv(db: FakeDb): Promise<Env> {
  const { ConvProjectionDO } = await import('../src/durable-objects/conv-projection');
  const { UserProjectionDO } = await import('../src/durable-objects/user-projection');
  const env = makeFakeEnv(db);
  const convs = new Map<string, InstanceType<typeof ConvProjectionDO>>();
  const users = new Map<string, InstanceType<typeof UserProjectionDO>>();
  const bind = <T extends { fetch(r: Request): Promise<Response> }>(
    cache: Map<string, T>,
    make: (n: string) => T,
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
  return env;
}

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

describe('runTitle → 会话列表投影', () => {
  it('标题写进数据库的同时也进了投影', async () => {
    const db = makeFakeDb({
      conversations: [
        {
          id: convId,
          conversation_type: 'user_bot',
          user_id: alice,
          bot_id: botId,
          feature: null,
          round_count: 1,
          title: null,
          updated_at: '2026-08-19T02:00:00+00:00',
        },
      ],
      conversation_participants: [
        { conversation_id: convId, participant_type: 'user', participant_id: alice },
      ],
      messages: [
        {
          id: 'm1',
          conversation_id: convId,
          role: 'user',
          content: '嗨',
          created_at: '2026-08-19T02:00:00+00:00',
          status: 'done',
        },
      ],
      user_unread_counts: [
        {
          user_id: alice,
          conversation_id: convId,
          unread_count: 0,
          last_message_preview: '嗨',
          last_message_at: '2026-08-19T02:00:00+00:00',
        },
      ],
    });
    const env = await makeEnv(db);
    // 冷启动回填一次(= 客户端拉过一次列表),再让参与者加入的 webhook 把这条
    // 会话落进投影 —— 此时标题还是空的,正是「新对话」那一屏。
    await listFor(env, alice);
    const { projectWebhookRow, projectUnreadRow } = await import(
      '../src/lib/projection-writethrough'
    );
    await projectWebhookRow(env, 'conversation_participants', 'insert', {
      conversation_id: convId,
      participant_type: 'user',
      participant_id: alice,
      joined_at: '2026-08-19T01:00:00+00:00',
    });
    await projectUnreadRow(env, db.rows.user_unread_counts![0]!);
    expect((await listFor(env, alice)).rows[0]!.title).toBeNull();

    const { runTitle } = await import('../src/lib/title-runner');
    await runTitle({ env, conversationId: convId });

    // 数据库里写上了
    expect(db.rows.conversations![0]!.title).toBe('打招呼');
    // 投影里也是新标题 —— 这一条以前永远不会发生
    const row = (await listFor(env, alice)).rows[0]!;
    expect(row.title).toBe('打招呼');
    // 顺带:预览没被这次会话级写穿冲掉
    expect(row.last_msg_preview).toBe('嗨');
  });
});
