import { describe, expect, it, vi } from 'vitest';
import {
  contributeToGroup,
  refundContributorFromGroup,
  dissolveGroup,
  applyGroupSpendDecay,
  getActivePledges,
  setPledge,
  withdrawFromGroup,
} from './group-wallet';
import { makeFakeDb, makeFakeClient, makeFakeEnv, type FakeDb, type FakeWallet } from '../../tests/_helpers/fake-supabase';
import type { PolarClient } from './polar-client';

const GROUP = 'subj_group_1';
const ALICE = 'user_alice';

function fakeOm() {
  return {
    reportUsage: vi.fn().mockResolvedValue(undefined),
    grantCredits: vi.fn().mockResolvedValue(undefined),
    reduceCredits: vi.fn().mockResolvedValue(undefined),
    getBalance: vi.fn().mockResolvedValue(0),
  } as unknown as PolarClient & {
    reportUsage: ReturnType<typeof vi.fn>;
    grantCredits: ReturnType<typeof vi.fn>;
    reduceCredits: ReturnType<typeof vi.fn>;
  };
}

function ctx(db: FakeDb, balances: Record<string, number>) {
  const wallet: FakeWallet = { calls: [], balances };
  const env = makeFakeEnv(db, { wallet });
  const supa = makeFakeClient(db);
  return { env, supa, wallet };
}

describe('contributeToGroup', () => {
  it('扣出资人 usage + 群侧入账 + 记 contribution', async () => {
    const db = makeFakeDb({ group_pools: [], group_contributions: [], pnc_ledger: [] });
    db.rpcs = {
      apply_group_contribution: () => ({ data: 1 }), // join index 1.0
    };
    const { env, supa, wallet } = ctx(db, { [ALICE]: 100_000_000 });
    const om = fakeOm();

    const r = await contributeToGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE, pncMicros: 27_000_000 });

    expect(r.ok).toBe(true);
    // 出资人扣 usage(Polar + DO debit)
    expect((om as any).reportUsage).toHaveBeenCalledWith(ALICE, 27_000_000, expect.objectContaining({ category: 'group_topup' }));
    expect(wallet.calls.some((c) => c.subjectId === ALICE && c.path === '/debit')).toBe(true);
    // 群侧入账(Polar grant + DO credit)
    expect((om as any).grantCredits).toHaveBeenCalledWith(GROUP, 27_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/credit')).toBe(true);
    // contribution 落库带 join index
    const contrib = db.inserts.find((i) => i.table === 'group_contributions');
    expect(contrib?.row.share_index_at_join).toBe(1);
    expect(contrib?.row.contributed_pnc_micros).toBe(27_000_000);
  });

  it('余额不足拒绝,不动 Polar', async () => {
    const db = makeFakeDb({ group_pools: [], group_contributions: [], pnc_ledger: [] });
    const { env, supa } = ctx(db, { [ALICE]: 10_000_000 });
    const om = fakeOm();
    const r = await contributeToGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE, pncMicros: 27_000_000 });
    expect(r).toEqual({ ok: false, reason: 'insufficient_balance' });
    expect((om as any).reportUsage).not.toHaveBeenCalled();
  });

  it('金额非法拒绝', async () => {
    const db = makeFakeDb({});
    const { env, supa } = ctx(db, { [ALICE]: 100_000_000 });
    const r = await contributeToGroup({ env, supa, om: fakeOm(), subjectId: GROUP, contributorUserId: ALICE, pncMicros: 0 });
    expect(r).toEqual({ ok: false, reason: 'invalid_amount' });
  });
});

describe('refundContributorFromGroup', () => {
  it('按 share_now 退款(夹到池),群出账+用户入账+标记 refunded', async () => {
    const db = makeFakeDb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 100_000_000, share_index: 0.5 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_group_refund: () => ({ data: null }) };
    const { env, supa, wallet } = ctx(db, { [GROUP]: 100_000_000, [ALICE]: 0 });
    const om = fakeOm();

    const r = await refundContributorFromGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE });

    // share_now = 100M * 0.5/1.0 = 50M
    expect(r).toMatchObject({ ok: true, refundedMicros: 50_000_000, contributionsRefunded: 1 });
    expect((om as any).reduceCredits).toHaveBeenCalledWith(GROUP, 50_000_000, expect.any(Object));
    expect((om as any).grantCredits).toHaveBeenCalledWith(ALICE, 50_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/debit')).toBe(true);
    expect(wallet.calls.some((c) => c.subjectId === ALICE && c.path === '/credit')).toBe(true);
    const c1 = db.rows.group_contributions.find((c) => c.id === 'c1');
    expect(c1?.status).toBe('refunded');
  });

  it('池已花光退 0,但仍标记 refunded,不动 Polar', async () => {
    const db = makeFakeDb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 0, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
      ],
      pnc_ledger: [],
    });
    const { env, supa } = ctx(db, { [GROUP]: 0, [ALICE]: 0 });
    const om = fakeOm();
    const r = await refundContributorFromGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE });
    expect(r).toMatchObject({ ok: true, refundedMicros: 0 });
    expect((om as any).reduceCredits).not.toHaveBeenCalled();
    expect(db.rows.group_contributions[0].status).toBe('refunded');
  });

  it('无 active 注资返回 no_contributions', async () => {
    const db = makeFakeDb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 10, share_index: 1 }],
      group_contributions: [],
    });
    const { env, supa } = ctx(db, {});
    const r = await refundContributorFromGroup({ env, supa, om: fakeOm(), subjectId: GROUP, contributorUserId: ALICE });
    expect(r).toEqual({ ok: false, reason: 'no_contributions' });
  });
});

describe('dissolveGroup', () => {
  it('退所有 active 出资人', async () => {
    const db = makeFakeDb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 200_000_000, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
        { id: 'c2', subject_id: GROUP, contributor_user_id: 'user_bob', contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_group_refund: () => ({ data: null }) };
    const { env, supa } = ctx(db, { [GROUP]: 200_000_000, [ALICE]: 0, user_bob: 0 });
    const r = await dissolveGroup({ env, supa, om: fakeOm(), subjectId: GROUP });
    expect(r.refundedContributors).toBe(2);
    expect(db.rows.group_contributions.every((c) => c.status === 'refunded')).toBe(true);
  });
});

describe('setPledge / getActivePledges', () => {
  it('upsert 认缴额度', async () => {
    const db = makeFakeDb({ group_pledges: [] });
    const supa = makeFakeClient(db);
    await setPledge(supa, GROUP, ALICE, 27_000_000);
    const row = db.inserts.find((i) => i.table === 'group_pledges')?.row;
    expect(row).toMatchObject({
      subject_id: GROUP,
      user_id: ALICE,
      pledge_pnc_micros: 27_000_000,
      status: 'active',
    });
  });

  it('额度 0 = 撤销', async () => {
    const db = makeFakeDb({ group_pledges: [] });
    await setPledge(makeFakeClient(db), GROUP, ALICE, 0);
    expect(db.inserts.find((i) => i.table === 'group_pledges')?.row.status).toBe('revoked');
  });

  it('getActivePledges 读 active', async () => {
    const db = makeFakeDb({
      group_pledges: [
        { subject_id: GROUP, user_id: ALICE, pledge_pnc_micros: 27_000_000, status: 'active' },
        { subject_id: GROUP, user_id: 'u_x', pledge_pnc_micros: 5, status: 'revoked' },
      ],
    });
    const pledges = await getActivePledges(makeFakeClient(db), GROUP);
    expect(pledges).toEqual([{ userId: ALICE, pledgeMicros: 27_000_000 }]);
  });
});

describe('withdrawFromGroup (部分取出)', () => {
  it('退≤share_now,池减、个人入账、缩 contributions', async () => {
    const db = makeFakeDb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 100_000_000, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_partial_withdraw: () => ({ data: 30_000_000 }) };
    const { env, supa, wallet } = ctx(db, { [GROUP]: 100_000_000, [ALICE]: 0 });
    const om = fakeOm();
    const r = await withdrawFromGroup({ env, supa, om, subjectId: GROUP, userId: ALICE, amountMicros: 30_000_000 });
    expect(r.withdrawnMicros).toBe(30_000_000);
    expect((om as any).reduceCredits).toHaveBeenCalledWith(GROUP, 30_000_000, expect.any(Object));
    expect((om as any).grantCredits).toHaveBeenCalledWith(ALICE, 30_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/debit')).toBe(true);
    expect(wallet.calls.some((c) => c.subjectId === ALICE && c.path === '/credit')).toBe(true);
  });

  it('RPC 退 0(份额/池为空)→ 不动 Polar', async () => {
    const db = makeFakeDb({ pnc_ledger: [] });
    db.rpcs = { apply_partial_withdraw: () => ({ data: 0 }) };
    const { env, supa } = ctx(db, {});
    const om = fakeOm();
    const r = await withdrawFromGroup({ env, supa, om, subjectId: GROUP, userId: ALICE, amountMicros: 30_000_000 });
    expect(r.withdrawnMicros).toBe(0);
    expect((om as any).reduceCredits).not.toHaveBeenCalled();
  });
});

describe('applyGroupSpendDecay', () => {
  it('调 apply_group_pool_spend RPC', async () => {
    const db = makeFakeDb({});
    const spy = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: spy };
    const supa = makeFakeClient(db);
    await applyGroupSpendDecay(supa, GROUP, 27_000_000);
    expect(spy).toHaveBeenCalledWith({ p_subject_id: GROUP, p_spend_micros: 27_000_000 });
  });

  it('非正金额跳过', async () => {
    const db = makeFakeDb({});
    const spy = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: spy };
    await applyGroupSpendDecay(makeFakeClient(db), GROUP, 0);
    expect(spy).not.toHaveBeenCalled();
  });
});
