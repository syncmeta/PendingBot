// 失败回合的 audit 行不能因为会话被回滚删掉就整条丢掉。
//
// `POST /v1/messages/start` 在第一轮什么都没产出时会把刚建的会话整条删掉
// （routes/messages.ts 的 `!producedOutput` 分支）。而这一轮的 audit 消息在
// 那之前就已经入队了，等消费端真正 INSERT 时，它引用的会话已经不存在 →
// `audit_log_conversation_id_fkey` 报 23503 → 抛错 → 队列重试 → 会话不会
// 回来，5 次全败 → 进 DLQ。线上表现就是 audit_log 里 status='error' 的行
// 从建库至今是 0（见 docs/tech-debt.md）。
//
// 注意：给那条外键加 `ON DELETE SET NULL` **救不了这一路** —— 删除发生在
// 插入之前，压根没有一行可供 SET NULL。所以修在插入侧：撞到外键就把
// conversation_id 置空重试一次，把「整条丢掉」降级成「丢掉会话关联」。

import { describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type Row,
} from '../../tests/_helpers/fake-supabase';

vi.mock('../lib/llm-trace', () => ({
  traceGeneration: async () => {},
}));

installFakeSupabaseMock();

import { isForeignKeyViolation, persistAuditMessage } from './router';
import type { AuditMessage } from '../queue/audit-types';

const TURN_ID = '018f4444-4444-7444-8444-444444444444';
const DEAD_CONV = '018f4444-dead-7444-8444-444444444444';

/// The exact shape PostgREST hands back for a foreign-key violation.
function fkViolation() {
  return {
    code: '23503',
    message:
      'insert or update on table "audit_log" violates foreign key ' +
      'constraint "audit_log_conversation_id_fkey"',
  };
}

/// A db whose audit_log INSERT rejects any row that still points at the
/// (already deleted) conversation — i.e. Postgres enforcing the FK.
function dbRejectingDeadConv() {
  const db = makeFakeDb({
    subjects: [{ id: 'subj-1', kind: 'user_account', user_id: 'user-9' }],
  });
  db.errors = {
    insert: (table: string, row: Row) =>
      table === 'audit_log' && row.conversation_id === DEAD_CONV
        ? fkViolation()
        : null,
  };
  return db;
}

function failedTurnMessage(conversationId: string | null): AuditMessage {
  return {
    auditId: TURN_ID,
    latencyMs: 42,
    route: null,
    opts: {
      userId: null,
      conversationId,
      taskType: 'message_reply',
      status: 'error',
      errorClass: 'not_found',
      tag: 'moonshotai/kimi-k3',
      routeTrace: [
        {
          attempt: 1,
          provider_slug: 'openrouter',
          status: 'fatal_err',
          error_class: 'not_found',
          error_message: 'No endpoints available matching your guardrail restrictions',
          latency_ms: 42,
        },
      ],
    },
  } as unknown as AuditMessage;
}

function envFor(db: ReturnType<typeof makeFakeDb>) {
  const env = makeFakeEnv(db) as unknown as Record<string, unknown>;
  env.CF_ACCOUNT_ID = 'acct-1';
  env.CF_AIG_GATEWAY = 'gw-1';
  env.CF_AIG_RUN_TOKEN = 'run-token';
  return env as never;
}

describe('isForeignKeyViolation', () => {
  it('recognises the SQLSTATE', () => {
    expect(isForeignKeyViolation({ code: '23503', message: 'whatever' })).toBe(true);
  });

  it('falls back to the message when the code is missing', () => {
    expect(
      isForeignKeyViolation({
        message: 'insert violates foreign key constraint "x_fkey"',
      }),
    ).toBe(true);
  });

  it('does not swallow unrelated failures', () => {
    expect(isForeignKeyViolation({ code: '23505', message: 'duplicate key' })).toBe(false);
    expect(isForeignKeyViolation({ message: 'connection reset' })).toBe(false);
  });
});

describe('persistAuditMessage — the conversation vanished mid-flight', () => {
  it('still lands the row, with conversation_id nulled', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const db = dbRejectingDeadConv();

    await persistAuditMessage(envFor(db), failedTurnMessage(DEAD_CONV));

    const rows = db.rows.audit_log ?? [];
    expect(rows).toHaveLength(1);
    const row = rows[0]!;
    // The row exists — that is the whole point. Before this fix the throw
    // above sent it round the retry loop and into the DLQ.
    expect(row.id).toBe(TURN_ID);
    expect(row.status).toBe('error');
    expect(row.error_class).toBe('not_found');
    expect(row.route_trace).toBeTruthy();
    // Only the conversation link is lost.
    expect(row.conversation_id).toBeNull();
    // …and it is recoverable from metadata rather than silently gone.
    expect((row.metadata as Record<string, unknown>).orphaned_conversation_id).toBe(
      DEAD_CONV,
    );
  });

  it('keeps the conversation link when the conversation is still there', async () => {
    const db = makeFakeDb({
      subjects: [{ id: 'subj-1', kind: 'user_account', user_id: 'user-9' }],
    });

    await persistAuditMessage(envFor(db), failedTurnMessage('018f4444-live-7444-8444-444444444444'));

    const row = (db.rows.audit_log ?? [])[0]!;
    expect(row.conversation_id).toBe('018f4444-live-7444-8444-444444444444');
    expect((row.metadata as Record<string, unknown> | undefined)?.orphaned_conversation_id)
      .toBeUndefined();
  });

  it('still throws (so the queue retries) on a failure that is not the FK', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const db = makeFakeDb({
      subjects: [{ id: 'subj-1', kind: 'user_account', user_id: 'user-9' }],
    });
    db.errors = {
      insert: (table: string) =>
        table === 'audit_log' ? { code: '08006', message: 'connection failure' } : null,
    };

    await expect(
      persistAuditMessage(envFor(db), failedTurnMessage(DEAD_CONV)),
    ).rejects.toThrow(/audit_log upsert failed/);
    expect(db.rows.audit_log ?? []).toHaveLength(0);
  });

  it('does not retry when there was no conversation to blame', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const db = makeFakeDb({
      subjects: [{ id: 'subj-1', kind: 'user_account', user_id: 'user-9' }],
    });
    db.errors = { insert: (table: string) => (table === 'audit_log' ? fkViolation() : null) };

    // conversation_id is already null — the FK it tripped is a different
    // one (user_id), and nulling the conversation cannot help. Throw so the
    // queue retries rather than silently mangling the row.
    await expect(
      persistAuditMessage(envFor(db), failedTurnMessage(null)),
    ).rejects.toThrow(/audit_log upsert failed/);
  });
});
