import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from '../../tests/_helpers/fake-supabase';
import { _resetMarkupCache } from '../lib/billing';
import { persistAuditMessage } from './router';

installFakeSupabaseMock();

function seedConversationBilling(conversationType: string, subjectId = 'subject-1'): FakeDb {
  const db = makeFakeDb({
    billing_config: [{ key: 'markup', value: 1 }],
    conversations: [{ id: 'conv-1', conversation_type: conversationType }],
    temporary_group_meta: [
      { conversation_id: 'conv-1', responsible_subject_id: subjectId },
    ],
  });
  return db;
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

describe('persistAuditMessage conversation billing target', () => {
  beforeEach(() => {
    _resetMarkupCache();
    vi.restoreAllMocks();
  });

  it('debits a crew conversation to its responsible subject wallet', async () => {
    const db = seedConversationBilling('crew');
    const debitSubject = vi.fn(() => ({ data: 973, error: null }));
    const debitUser = vi.fn(() => ({ data: 973, error: null }));
    db.rpcs = {
      billing_debit_subject: debitSubject,
      billing_debit: debitUser,
    };

    await persistAuditMessage(makeFakeEnv(db), auditMessage());

    expect(debitSubject).toHaveBeenCalledWith({
      p_subject_id: 'subject-1',
      p_audit_log_id: '018f1111-1111-7111-8111-111111111111',
      p_credits: 27,
    });
    expect(debitUser).not.toHaveBeenCalled();
    const auditRow = db.inserts.find((i) => i.table === 'audit_log')?.row;
    expect(auditRow?.billing_status).toBe('pending');
    expect(auditRow?.metadata).toMatchObject({
      billing_target_kind: 'subject',
      billing_subject_id: 'subject-1',
    });
  });

  it('prefers the conversation subject over a caller-supplied user id', async () => {
    const db = seedConversationBilling('temporary_group', 'subject-2');
    const debitSubject = vi.fn(() => ({ data: 940, error: null }));
    const debitUser = vi.fn(() => ({ data: 940, error: null }));
    db.rpcs = {
      billing_debit_subject: debitSubject,
      billing_debit: debitUser,
    };

    await persistAuditMessage(makeFakeEnv(db), auditMessage({ userId: 'user-1' }));

    expect(debitSubject).toHaveBeenCalledWith({
      p_subject_id: 'subject-2',
      p_audit_log_id: '018f1111-1111-7111-8111-111111111111',
      p_credits: 27,
    });
    expect(debitUser).not.toHaveBeenCalled();
  });
});
