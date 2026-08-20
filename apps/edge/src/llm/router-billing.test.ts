import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type FakeWallet,
} from '../../tests/_helpers/fake-supabase';
import { persistAuditMessage } from './router';

installFakeSupabaseMock();

// 计费 P2: persistAuditMessage settles the turn's spend via WalletDO
// (wallet.debit) — NOT the old settleTurnV2 → settleUsage packs path. It
// writes the audit_log row (turn metadata) and debits the resolved owner's
// WalletDO. Here we assert OWNER RESOLUTION + the debit shape (subject,
// pnc micros, category, dedupeId) + that no v1 RPC fires.

function seedConversationBilling(conversationType: string, subjectId = 'subject-1'): FakeDb {
  return makeFakeDb({
    conversations: [
      {
        id: 'conv-1',
        conversation_type: conversationType,
        responsible_subject_id: subjectId,
      },
    ],
    temporary_group_meta: [
      { conversation_id: 'conv-1', responsible_subject_id: subjectId },
    ],
  });
}

function freshWallet(): FakeWallet {
  return { calls: [], balances: {} };
}

function auditMessage(overrides: Record<string, unknown> = {}) {
  return {
    auditId: '018f1111-1111-7111-8111-111111111111',
    latencyMs: 42,
    route: {
      modelToCall: 'openai/gpt-5-mini',
      provider: { slug: 'openrouter', apiStyle: 'chat' },
    },
    opts: {
      taskType: 'crew_turn',
      status: 'success',
      conversationId: 'conv-1',
      providerCostUsd: 0.01,
      ...overrides,
    },
  } as never;
}

describe('persistAuditMessage WalletDO billing owner resolution', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('debits a crew conversation against its responsible subject (from temporary_group_meta)', async () => {
    const db = seedConversationBilling('crew');
    const debitUser = vi.fn(() => ({ data: 973, error: null }));
    const debitSubject = vi.fn(() => ({ data: 973, error: null }));
    db.rpcs = { billing_debit: debitUser, billing_debit_subject: debitSubject };
    const w = freshWallet();

    await persistAuditMessage(makeFakeEnv(db, { wallet: w }), auditMessage());

    // No v1 debit RPCs.
    expect(debitUser).not.toHaveBeenCalled();
    expect(debitSubject).not.toHaveBeenCalled();

    // Audit row is turn metadata only: billing_status 'billed', cost_credits 0.
    const auditRow = db.inserts.find((i) => i.table === 'audit_log')?.row;
    expect(auditRow?.billing_status).toBe('billed');
    expect(auditRow?.cost_credits).toBe(0);
    expect(auditRow?.metadata).toMatchObject({
      billing_target_kind: 'subject',
      billing_subject_id: 'subject-1',
    });

    // WalletDO debit owned by the subject. 0.01 USD × 27 PNC/USD = 0.27 PNC
    // → 270_000 pnc micros. dedupeId is the audit id (idempotency key).
    const debit = w.calls.find((c) => c.path === '/debit');
    expect(debit?.subjectId).toBe('subject-1');
    expect(debit?.body.pncMicros).toBe(270000);
    expect(debit?.body.category).toBe('llm_tokens');
    expect(debit?.body.dedupeId).toBe('018f1111-1111-7111-8111-111111111111');
  });

  it('prefers the conversation subject over a caller-supplied user id', async () => {
    const db = seedConversationBilling('temporary_group', 'subject-2');
    const debitUser = vi.fn(() => ({ data: 940, error: null }));
    db.rpcs = { billing_debit: debitUser };
    const w = freshWallet();

    await persistAuditMessage(
      makeFakeEnv(db, { wallet: w }),
      auditMessage({ userId: 'user-1' }),
    );

    expect(debitUser).not.toHaveBeenCalled();
    const debit = w.calls.find((c) => c.path === '/debit');
    expect(debit?.subjectId).toBe('subject-2');
  });

  it('1v1 扣的是发起用户的 user_account subject 钱包(不是 auth user id)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'conv-1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
      subjects: [{ id: 'user-9-sub', user_id: 'user-9', kind: 'user_account' }],
    });
    const w = freshWallet();

    await persistAuditMessage(
      makeFakeEnv(db, { wallet: w }),
      auditMessage({ taskType: 'reply', userId: 'user-9' }),
    );

    const debit = w.calls.find((c) => c.path === '/debit');
    expect(debit?.subjectId).toBe('user-9-sub');
    expect(debit?.body.category).toBe('llm_tokens');
    const auditRow = db.inserts.find((i) => i.table === 'audit_log')?.row;
    expect(auditRow?.metadata).toMatchObject({
      billing_target_kind: 'user',
      billing_subject_id: 'user-9-sub',
    });
  });

  it('主体解析不到 → 回合照常落库、不扣费、报错级日志(不猜一个键去扣)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'conv-1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
      subjects: [],
    });
    const w = freshWallet();
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);

    await persistAuditMessage(
      makeFakeEnv(db, { wallet: w }),
      auditMessage({ taskType: 'reply', userId: 'ghost-user' }),
    );

    expect(w.calls.find((c) => c.path === '/debit')).toBeUndefined();
    expect(err).toHaveBeenCalled();
    const auditRow = db.inserts.find((i) => i.table === 'audit_log')?.row;
    expect(auditRow?.billing_status).toBe('free');
  });

  it('debits each web-tool call with a namespaced dedupeId', async () => {
    const db = seedConversationBilling('crew');
    const w = freshWallet();

    await persistAuditMessage(
      makeFakeEnv(db, { wallet: w }),
      auditMessage({
        providerCostUsd: 0.01,
        webTools: [
          { provider: 'brave', kind: 'search', target: 'q', status: 'success', latencyMs: 1, costUsd: 0.005 },
          { provider: 'tavily', kind: 'search', target: 'q2', status: 'success', latencyMs: 1, costUsd: 0.005 },
        ],
      }),
    );

    const toolDebits = w.calls.filter(
      (c) => c.path === '/debit' && c.body.category === 'web_tools',
    );
    expect(toolDebits).toHaveLength(2);
    expect(toolDebits[0].body.dedupeId).toBe('018f1111-1111-7111-8111-111111111111:tool:0');
    expect(toolDebits[1].body.dedupeId).toBe('018f1111-1111-7111-8111-111111111111:tool:1');
    // 0.005 USD × 27 = 0.135 PNC → 135_000 micros.
    expect(toolDebits[0].body.pncMicros).toBe(135000);
  });

  it('does not debit a zero-cost turn', async () => {
    const db = seedConversationBilling('crew');
    const w = freshWallet();

    await persistAuditMessage(
      makeFakeEnv(db, { wallet: w }),
      auditMessage({ providerCostUsd: 0 }),
    );

    expect(w.calls.find((c) => c.path === '/debit')).toBeUndefined();
    const auditRow = db.inserts.find((i) => i.table === 'audit_log')?.row;
    expect(auditRow?.billing_status).toBe('skipped');
  });
});
