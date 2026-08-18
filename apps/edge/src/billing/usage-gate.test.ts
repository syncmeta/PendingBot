import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeWallet,
} from '../../tests/_helpers/fake-supabase';
import { serviceClient } from '../lib/supabase';
import { gateConversation, resolveBillingSubjectId } from './usage-gate';
import { WalletSubjectUnresolvedError } from './subject-key';

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

  it('1v1 → 发起用户的 user_account subject(不是 auth user id)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
      subjects: [{ id: 'u1-sub', user_id: 'u1', kind: 'user_account' }],
    });
    const supa = serviceClient(makeFakeEnv(db));
    const t = await resolveBillingSubjectId(supa, { conversationId: 'c1', userId: 'u1' });
    expect(t).toEqual({ subjectId: 'u1-sub', kind: 'user' });
  });

  it('个人主体解析不到 → 抛 WalletSubjectUnresolvedError(不静默用 user id)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
      subjects: [],
    });
    const supa = serviceClient(makeFakeEnv(db));
    await expect(
      resolveBillingSubjectId(supa, { conversationId: 'c1', userId: 'no-subject-user' }),
    ).rejects.toBeInstanceOf(WalletSubjectUnresolvedError);
  });

  it('no conv + no user → null (unbilled system turn)', async () => {
    const db = makeFakeDb({});
    const supa = serviceClient(makeFakeEnv(db));
    expect(await resolveBillingSubjectId(supa, {})).toBeNull();
  });
});

describe('gateConversation 个人钱包主体键', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('读的是 user_account subject 那个钱包 —— 钱在 subject 上就该放行', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
      subjects: [{ id: 'alice-sub', user_id: 'alice', kind: 'user_account' }],
    });
    const w = wallet();
    w.balances['alice-sub'] = 100 * PNC; // 充值都记在主体上
    w.balances['alice'] = 0; // auth user id 那个 DO 永远是空的
    const env = makeFakeEnv(db, { wallet: w });
    const r = await gateConversation(env, serviceClient(env), { conversationId: 'c1', userId: 'alice' });
    expect(r).toBeNull(); // 放行
    expect(w.calls.map((c) => c.subjectId)).toEqual(['alice-sub']);
  });

  it('主体解析不到 → fail-open + 记日志(不静默判成余额耗尽)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
      subjects: [],
    });
    const w = wallet();
    const env = makeFakeEnv(db, { wallet: w });
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const r = await gateConversation(env, serviceClient(env), { conversationId: 'c1', userId: 'ghost' });
    expect(r).toBeNull();
    expect(w.calls).toEqual([]);
    expect(err).toHaveBeenCalled();
  });
});

describe('gateConversation kill-switch', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('kill-switch off → never gates even when exhausted (no-op pass)', async () => {
    const db = makeFakeDb({
      conversations: [
        { id: 'c1', conversation_type: 'user_bot', responsible_subject_id: null },
      ],
    });
    const w = wallet();
    w.balances['u1'] = 0;
    const env = makeFakeEnv(db, { wallet: w });
    (env as unknown as { BILLING_ENABLED?: string }).BILLING_ENABLED = 'false';
    const r = await gateConversation(env, serviceClient(env), { conversationId: 'c1', userId: 'u1' });
    expect(r).toBeNull();
  });
});

describe('availableForSubject (群聚合认缴)', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('群可用 = 实缴池 + Σ认缴 min(pledge,余额)', async () => {
    const db = makeFakeDb({
      group_pledges: [
        { subject_id: 'grp', user_id: 'bob', pledge_pnc_micros: 40 * PNC, status: 'active' },
      ],
      // 认缴成员的个人钱包按其 user_account subject 读,不是 auth user id。
      subjects: [{ id: 'bob-sub', user_id: 'bob', kind: 'user_account' }],
    });
    const w: FakeWallet = { calls: [], balances: { grp: 60 * PNC, 'bob-sub': 100 * PNC } };
    const env = makeFakeEnv(db, { wallet: w });
    const supa = serviceClient(env);
    const { availableForSubject } = await import('./usage-gate');
    const r = await availableForSubject(env, supa, { subjectId: 'grp', kind: 'subject' });
    expect(r.balanceMicros).toBe(100 * PNC); // 60 池 + 40 认缴
    expect(r.thresholdState).toBe('sufficient');
  });

  it('个人 = 自己 WalletDO', async () => {
    const db = makeFakeDb({});
    const w: FakeWallet = { calls: [], balances: { 'u1-sub': 3 * PNC } };
    const env = makeFakeEnv(db, { wallet: w });
    const { availableForSubject } = await import('./usage-gate');
    const r = await availableForSubject(env, serviceClient(env), { subjectId: 'u1-sub', kind: 'user' });
    expect(r.balanceMicros).toBe(3 * PNC);
    expect(r.thresholdState).toBe('throttle');
  });
});
