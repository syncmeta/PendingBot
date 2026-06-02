import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeWallet,
} from '../../tests/_helpers/fake-supabase';
import { serviceClient } from '../lib/supabase';
import { gateUsage, resolveBillingSubjectId } from './usage-gate';
import { InsufficientBalanceError } from '../lib/billing';

installFakeSupabaseMock();

const PNC = 1_000_000;

function wallet(): FakeWallet {
  return { calls: [], balances: {} };
}

describe('resolveBillingSubjectId', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('group → conversations.responsible_subject_id', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'group', responsible_subject_id: 'grp-sub' },
      ],
    });
    const supa = serviceClient(makeFakeEnv(db));
    const t = await resolveBillingSubjectId(supa, { conversationId: 'c1', userId: 'u1' });
    expect(t).toEqual({ subjectId: 'grp-sub', kind: 'subject' });
  });

  it('crew → temporary_group_meta.responsible_subject_id (not conversations)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'crew', responsible_subject_id: 'wrong-conv-sub' },
      ],
      temporary_group_meta: [{ conversation_id: 'c1', responsible_subject_id: 'crew-sub' }],
    });
    const supa = serviceClient(makeFakeEnv(db));
    const t = await resolveBillingSubjectId(supa, { conversationId: 'c1', userId: 'u1' });
    expect(t).toEqual({ subjectId: 'crew-sub', kind: 'subject' });
  });

  it('1v1 → initiating user', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
    });
    const supa = serviceClient(makeFakeEnv(db));
    const t = await resolveBillingSubjectId(supa, { conversationId: 'c1', userId: 'u1' });
    expect(t).toEqual({ subjectId: 'u1', kind: 'user' });
  });

  it('no conv + no user → null (unbilled system turn)', async () => {
    const db = makeFakeDb({});
    const supa = serviceClient(makeFakeEnv(db));
    expect(await resolveBillingSubjectId(supa, {})).toBeNull();
  });
});

describe('gateUsage thresholds', () => {
  beforeEach(() => vi.restoreAllMocks());

  function setup(balanceMicros: number) {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
    });
    const w = wallet();
    w.balances['u1'] = balanceMicros;
    const env = makeFakeEnv(db, { wallet: w });
    return { env, supa: serviceClient(env), w };
  }

  it('exhausted (≤0) → throws InsufficientBalanceError', async () => {
    const { env, supa } = setup(0);
    await expect(gateUsage(env, supa, { conversationId: 'c1', userId: 'u1' })).rejects.toBeInstanceOf(
      InsufficientBalanceError,
    );
  });

  it('throttle (<5 PNC) → passes with state throttle', async () => {
    const { env, supa } = setup(3 * PNC);
    const r = await gateUsage(env, supa, { conversationId: 'c1', userId: 'u1' });
    expect(r?.thresholdState).toBe('throttle');
  });

  it('low (<50 PNC) → passes with state low', async () => {
    const { env, supa } = setup(20 * PNC);
    const r = await gateUsage(env, supa, { conversationId: 'c1', userId: 'u1' });
    expect(r?.thresholdState).toBe('low');
  });

  it('sufficient (≥50 PNC) → passes with state sufficient', async () => {
    const { env, supa } = setup(100 * PNC);
    const r = await gateUsage(env, supa, { conversationId: 'c1', userId: 'u1' });
    expect(r?.thresholdState).toBe('sufficient');
    expect(r?.subjectId).toBe('u1');
  });

  it('no billable subject → no-op pass (null)', async () => {
    const db = makeFakeDb({});
    const env = makeFakeEnv(db, { wallet: wallet() });
    const r = await gateUsage(env, serviceClient(env), {});
    expect(r).toBeNull();
  });
});
