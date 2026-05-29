import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from '../../tests/_helpers/fake-supabase';
import { persistAuditMessage } from './router';

installFakeSupabaseMock();

// Billing v2 cutover: persistAuditMessage no longer calls the v1
// billing_debit* RPCs. It writes the audit_log row (turn metadata) and
// settles the spend via settleTurnV2 → settleUsage, which records a
// usage_events row owned by the resolved billing owner. The deep settle
// mechanics (FIFO pack debit, ledger) are unit-tested in
// billing-v2.test.ts; here we assert the OWNER RESOLUTION + that no v1
// RPC fires.

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

describe('persistAuditMessage v2 billing owner resolution', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('settles a crew conversation against its responsible subject', async () => {
    const db = seedConversationBilling('crew');
    const debitUser = vi.fn(() => ({ data: 973, error: null }));
    const debitSubject = vi.fn(() => ({ data: 973, error: null }));
    db.rpcs = { billing_debit: debitUser, billing_debit_subject: debitSubject };

    await persistAuditMessage(makeFakeEnv(db), auditMessage());

    // No v1 debit RPCs post-cutover.
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

    // v2 usage_event owned by the subject. 0.01 USD → 270_000 PNC micros.
    const usageRow = db.inserts.find((i) => i.table === 'usage_events')?.row;
    expect(usageRow?.owner_subject_id).toBe('subject-1');
    expect(usageRow?.owner_user_id).toBeNull();
    expect(usageRow?.event_category).toBe('llm_tokens');
    expect(usageRow?.pnc_micros).toBe(270000);
  });

  it('prefers the conversation subject over a caller-supplied user id', async () => {
    const db = seedConversationBilling('temporary_group', 'subject-2');
    const debitUser = vi.fn(() => ({ data: 940, error: null }));
    const debitSubject = vi.fn(() => ({ data: 940, error: null }));
    db.rpcs = { billing_debit: debitUser, billing_debit_subject: debitSubject };

    await persistAuditMessage(makeFakeEnv(db), auditMessage({ userId: 'user-1' }));

    expect(debitUser).not.toHaveBeenCalled();
    expect(debitSubject).not.toHaveBeenCalled();

    const usageRow = db.inserts.find((i) => i.table === 'usage_events')?.row;
    expect(usageRow?.owner_subject_id).toBe('subject-2');
    expect(usageRow?.owner_user_id).toBeNull();
  });
});
