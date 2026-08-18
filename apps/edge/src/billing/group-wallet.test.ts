import { describe, expect, it, vi } from 'vitest';
import {
  contributeToGroup,
  refundContributorFromGroup,
  dissolveGroup,
  applyGroupSpendDecay,
  getActivePledges,
  setPledge,
  withdrawFromGroup,
  resolveGroupStakes,
  settleGroupSpend,
  clawbackFromGroups,
  readGroupWallet,
} from './group-wallet';
import { makeFakeDb, makeFakeClient, makeFakeEnv, type FakeDb, type FakeWallet } from '../../tests/_helpers/fake-supabase';
import type { PolarClient } from './polar-client';

const GROUP = 'subj_group_1';
// 线上形态:群成员表(group_contributions.contributor_user_id / group_pledges.user_id)
// 存的是 **auth user id**(外键指向 users),而个人钱包/Polar/pnc_ledger 用的是
// **user_account subject id**。两者是不同的 uuid,不能混用。
const ALICE = 'user_alice';
const ALICE_SUB = 'subj_alice';
const BOB = 'user_bob';
const BOB_SUB = 'subj_bob';
const SUBJECTS = [
  { id: ALICE_SUB, user_id: ALICE, kind: 'user_account' },
  { id: BOB_SUB, user_id: BOB, kind: 'user_account' },
];

/** 每个用例都带上 subjects 映射表 —— 个人钱包一律经它解析。 */
function gdb(seed: Record<string, Array<Record<string, unknown>>> = {}): FakeDb {
  return makeFakeDb({ subjects: SUBJECTS, ...seed });
}

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
    const db = gdb({ group_pools: [], group_contributions: [], pnc_ledger: [] });
    db.rpcs = {
      apply_group_contribution: () => ({ data: 1 }), // join index 1.0
    };
    const { env, supa, wallet } = ctx(db, { [ALICE_SUB]: 100_000_000 });
    const om = fakeOm();

    const r = await contributeToGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE, pncMicros: 27_000_000 });

    expect(r.ok).toBe(true);
    // 出资人扣 usage(Polar + DO debit)
    expect((om as any).reportUsage).toHaveBeenCalledWith(ALICE_SUB, 27_000_000, expect.objectContaining({ category: 'group_topup' }));
    expect(wallet.calls.some((c) => c.subjectId === ALICE_SUB && c.path === '/debit')).toBe(true);
    // 群侧入账(Polar grant + DO credit)
    expect((om as any).grantCredits).toHaveBeenCalledWith(GROUP, 27_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/credit')).toBe(true);
    // contribution 落库带 join index
    const contrib = db.inserts.find((i) => i.table === 'group_contributions');
    expect(contrib?.row.share_index_at_join).toBe(1);
    expect(contrib?.row.contributed_pnc_micros).toBe(27_000_000);
  });

  it('余额不足拒绝,不动 Polar', async () => {
    const db = gdb({ group_pools: [], group_contributions: [], pnc_ledger: [] });
    const { env, supa } = ctx(db, { [ALICE_SUB]: 10_000_000 });
    const om = fakeOm();
    const r = await contributeToGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE, pncMicros: 27_000_000 });
    expect(r).toEqual({ ok: false, reason: 'insufficient_balance' });
    expect((om as any).reportUsage).not.toHaveBeenCalled();
  });

  it('金额非法拒绝', async () => {
    const db = gdb({});
    const { env, supa } = ctx(db, { [ALICE_SUB]: 100_000_000 });
    const r = await contributeToGroup({ env, supa, om: fakeOm(), subjectId: GROUP, contributorUserId: ALICE, pncMicros: 0 });
    expect(r).toEqual({ ok: false, reason: 'invalid_amount' });
  });
});

describe('refundContributorFromGroup', () => {
  it('按 share_now 退款(夹到池),群出账+用户入账+标记 refunded', async () => {
    const db = gdb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 100_000_000, share_index: 0.5 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_group_refund: () => ({ data: null }) };
    const { env, supa, wallet } = ctx(db, { [GROUP]: 100_000_000, [ALICE_SUB]: 0 });
    const om = fakeOm();

    const r = await refundContributorFromGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE });

    // share_now = 100M * 0.5/1.0 = 50M
    expect(r).toMatchObject({ ok: true, refundedMicros: 50_000_000, contributionsRefunded: 1 });
    expect((om as any).reduceCredits).toHaveBeenCalledWith(GROUP, 50_000_000, expect.any(Object));
    expect((om as any).grantCredits).toHaveBeenCalledWith(ALICE_SUB, 50_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/debit')).toBe(true);
    expect(wallet.calls.some((c) => c.subjectId === ALICE_SUB && c.path === '/credit')).toBe(true);
    const c1 = db.rows.group_contributions.find((c) => c.id === 'c1');
    expect(c1?.status).toBe('refunded');
  });

  it('池已花光退 0,但仍标记 refunded,不动 Polar', async () => {
    const db = gdb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 0, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
      ],
      pnc_ledger: [],
    });
    const { env, supa } = ctx(db, { [GROUP]: 0, [ALICE_SUB]: 0 });
    const om = fakeOm();
    const r = await refundContributorFromGroup({ env, supa, om, subjectId: GROUP, contributorUserId: ALICE });
    expect(r).toMatchObject({ ok: true, refundedMicros: 0 });
    expect((om as any).reduceCredits).not.toHaveBeenCalled();
    expect(db.rows.group_contributions[0].status).toBe('refunded');
  });

  it('无 active 注资返回 no_contributions', async () => {
    const db = gdb({
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
    const db = gdb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 200_000_000, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
        { id: 'c2', subject_id: GROUP, contributor_user_id: BOB, contributed_pnc_micros: 100_000_000, share_index_at_join: 1.0, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_group_refund: () => ({ data: null }) };
    const { env, supa } = ctx(db, { [GROUP]: 200_000_000, [ALICE_SUB]: 0, [BOB_SUB]: 0 });
    const r = await dissolveGroup({ env, supa, om: fakeOm(), subjectId: GROUP });
    expect(r.refundedContributors).toBe(2);
    expect(db.rows.group_contributions.every((c) => c.status === 'refunded')).toBe(true);
  });
});

describe('setPledge / getActivePledges', () => {
  it('upsert 认缴额度', async () => {
    const db = gdb({ group_pledges: [] });
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
    const db = gdb({ group_pledges: [] });
    await setPledge(makeFakeClient(db), GROUP, ALICE, 0);
    expect(db.inserts.find((i) => i.table === 'group_pledges')?.row.status).toBe('revoked');
  });

  it('getActivePledges 读 active', async () => {
    const db = gdb({
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
    const db = gdb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 100_000_000, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_partial_withdraw: () => ({ data: 30_000_000 }) };
    const { env, supa, wallet } = ctx(db, { [GROUP]: 100_000_000, [ALICE_SUB]: 0 });
    const om = fakeOm();
    const r = await withdrawFromGroup({ env, supa, om, subjectId: GROUP, userId: ALICE, amountMicros: 30_000_000 });
    expect(r.withdrawnMicros).toBe(30_000_000);
    expect((om as any).reduceCredits).toHaveBeenCalledWith(GROUP, 30_000_000, expect.any(Object));
    expect((om as any).grantCredits).toHaveBeenCalledWith(ALICE_SUB, 30_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/debit')).toBe(true);
    expect(wallet.calls.some((c) => c.subjectId === ALICE_SUB && c.path === '/credit')).toBe(true);
  });

  it('RPC 退 0(份额/池为空)→ 不动 Polar', async () => {
    const db = gdb({ pnc_ledger: [] });
    db.rpcs = { apply_partial_withdraw: () => ({ data: 0 }) };
    const { env, supa } = ctx(db, {});
    const om = fakeOm();
    const r = await withdrawFromGroup({ env, supa, om, subjectId: GROUP, userId: ALICE, amountMicros: 30_000_000 });
    expect(r.withdrawnMicros).toBe(0);
    expect((om as any).reduceCredits).not.toHaveBeenCalled();
  });
});

describe('resolveGroupStakes', () => {
  it('S = 实缴池 + Σ认缴 min(pledge,余额)', async () => {
    const db = gdb({
      group_pledges: [{ subject_id: GROUP, user_id: BOB, pledge_pnc_micros: 40_000_000, status: 'active' }],
    });
    const { env, supa } = ctx(db, { [GROUP]: 60_000_000, [BOB_SUB]: 100_000_000 });
    const s = await resolveGroupStakes(env, supa, GROUP);
    expect(s.poolStake).toBe(60_000_000);
    expect(s.pledgeStakes).toEqual([{ userId: BOB, subjectId: BOB_SUB, stakeMicros: 40_000_000 }]);
    expect(s.total).toBe(100_000_000);
  });

  it('认缴成员余额低于 pledge → 份额缩到余额', async () => {
    const db = gdb({
      group_pledges: [{ subject_id: GROUP, user_id: BOB, pledge_pnc_micros: 40_000_000, status: 'active' }],
    });
    const { env, supa } = ctx(db, { [GROUP]: 60_000_000, [BOB_SUB]: 10_000_000 });
    const s = await resolveGroupStakes(env, supa, GROUP);
    expect(s.pledgeStakes[0].stakeMicros).toBe(10_000_000);
    expect(s.total).toBe(70_000_000);
  });
});

describe('resolveGroupStakes 主体解析失败', () => {
  it('认缴成员没有个人主体 → 该成员不计份额 + 留日志(不拿 user id 当钱包键)', async () => {
    const db = gdb({
      group_pledges: [
        { subject_id: GROUP, user_id: 'user_ghost', pledge_pnc_micros: 40_000_000, status: 'active' },
      ],
    });
    const { env, supa, wallet } = ctx(db, { [GROUP]: 60_000_000, user_ghost: 999_000_000 });
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);

    const s = await resolveGroupStakes(env, supa, GROUP);

    expect(s.pledgeStakes).toEqual([]);
    expect(s.total).toBe(60_000_000);
    expect(wallet.calls.some((c) => c.subjectId === 'user_ghost')).toBe(false);
    expect(err).toHaveBeenCalled();
    err.mockRestore();
  });
});

describe('settleGroupSpend', () => {
  it('按占比拆:实缴池衰减 + 认缴成员个人钱包直扣', async () => {
    const db = gdb({
      group_pledges: [{ subject_id: GROUP, user_id: BOB, pledge_pnc_micros: 40_000_000, status: 'active' }],
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 60_000_000, share_index: 1 }],
    });
    const decay = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: decay };
    // 池 60M + Bob 40M = S 100M;花 10M → 池摊 6M、Bob 摊 4M
    const { env, supa, wallet } = ctx(db, { [GROUP]: 60_000_000, [BOB_SUB]: 40_000_000 });
    await settleGroupSpend({ env, supa, subjectId: GROUP, spendMicros: 10_000_000, category: 'llm_tokens', dedupeId: 'audit1' });
    expect(wallet.calls.find((c) => c.subjectId === GROUP && c.path === '/debit')?.body.pncMicros).toBe(6_000_000);
    expect(decay).toHaveBeenCalledWith({ p_subject_id: GROUP, p_spend_micros: 6_000_000 });
    const bobDebit = wallet.calls.find((c) => c.subjectId === BOB_SUB && c.path === '/debit');
    expect(bobDebit?.body.pncMicros).toBe(4_000_000);
    expect(bobDebit?.body.dedupeId).toBe(`audit1:pledge:${BOB}`);
  });

  it('无份额(池空+无认缴)→ 整笔记群池透支', async () => {
    const db = gdb({ group_pledges: [], group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 0, share_index: 1 }] });
    const decay = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: decay };
    const { env, supa, wallet } = ctx(db, { [GROUP]: 0 });
    await settleGroupSpend({ env, supa, subjectId: GROUP, spendMicros: 5_000_000, category: 'llm_tokens', dedupeId: 'a2' });
    expect(wallet.calls.find((c) => c.subjectId === GROUP && c.path === '/debit')?.body.pncMicros).toBe(5_000_000);
  });
});

// 调用方(Polar / RevenueCat webhook)手上只有**个人 subject id**,而
// group_contributions.contributor_user_id 存的是 auth user id —— 这里必须反查一跳,
// 否则查不到任何注资,链式退款静默冲 0(注资进群→退购买款→群里的钱还在)。
describe('clawbackFromGroups (链式退款冲群)', () => {
  it('传入个人 subject id → 反查出 user id 找到注资并冲减', async () => {
    const db = gdb({
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 50_000_000, share_index_at_join: 1, status: 'active' },
      ],
      pnc_ledger: [],
    });
    db.rpcs = { apply_partial_withdraw: () => ({ data: 20_000_000 }) }; // 群只能冲 20M
    const { env, supa, wallet } = ctx(db, { [GROUP]: 50_000_000 });
    const om = fakeOm();
    const r = await clawbackFromGroups(env, supa, om, ALICE_SUB, 30_000_000);
    expect(r.clawedMicros).toBe(20_000_000);
    expect((om as any).reduceCredits).toHaveBeenCalledWith(GROUP, 20_000_000, expect.any(Object));
    // 群 DO 扣;不给 ALICE credit(用户拿上游现金)
    expect(wallet.calls.some((c) => c.subjectId === GROUP && c.path === '/debit')).toBe(true);
    expect(wallet.calls.some((c) => c.subjectId === ALICE_SUB && c.path === '/credit')).toBe(false);
  });

  it('用户无群贡献 → 冲 0', async () => {
    const db = gdb({ group_contributions: [], pnc_ledger: [] });
    const { env, supa } = ctx(db, {});
    const r = await clawbackFromGroups(env, supa, fakeOm(), ALICE_SUB, 30_000_000);
    expect(r.clawedMicros).toBe(0);
  });
});

describe('applyGroupSpendDecay', () => {
  it('调 apply_group_pool_spend RPC', async () => {
    const db = gdb({});
    const spy = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: spy };
    const supa = makeFakeClient(db);
    await applyGroupSpendDecay(supa, GROUP, 27_000_000);
    expect(spy).toHaveBeenCalledWith({ p_subject_id: GROUP, p_spend_micros: 27_000_000 });
  });

  it('非正金额跳过', async () => {
    const db = gdb({});
    const spy = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: spy };
    await applyGroupSpendDecay(makeFakeClient(db), GROUP, 0);
    expect(spy).not.toHaveBeenCalled();
  });
});

describe('readGroupWallet', () => {
  it('池余额 + S + 实缴 share_now + 认缴明细', async () => {
    // ALICE 实缴 50M(join idx 1,当前 idx 1 → share_now 50M);BOB 认缴 30M(余额 100M → 生效 30M)。
    const db = gdb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 50_000_000, share_index: 1 }],
      group_contributions: [
        { id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 50_000_000, share_index_at_join: 1, status: 'active' },
      ],
      group_pledges: [
        { subject_id: GROUP, user_id: BOB, pledge_pnc_micros: 30_000_000, status: 'active' },
      ],
    });
    // 池余额取自 GROUP 的 WalletDO 余额;BOB 个人余额 100M。
    const { env, supa } = ctx(db, { [GROUP]: 50_000_000, [BOB_SUB]: 100_000_000 });

    const view = await readGroupWallet(env, supa, GROUP);

    expect(view.poolMicros).toBe(50_000_000);
    expect(view.totalStakeMicros).toBe(80_000_000); // 池 50M + 认缴生效 30M
    const alice = view.members.find((m) => m.userId === ALICE)!;
    expect(alice.contributionShareNowMicros).toBe(50_000_000);
    expect(alice.pledgeMicros).toBe(0);
    expect(alice.stakeMicros).toBe(50_000_000);
    const bob = view.members.find((m) => m.userId === BOB)!;
    expect(bob.contributionShareNowMicros).toBe(0);
    expect(bob.pledgeMicros).toBe(30_000_000);
    expect(bob.pledgeEffectiveMicros).toBe(30_000_000);
    expect(bob.stakeMicros).toBe(30_000_000);
  });

  it('认缴成员余额见底 → 生效份额 0(欠费隔离),但仍在明细', async () => {
    const db = gdb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 0, share_index: 1 }],
      group_contributions: [],
      group_pledges: [{ subject_id: GROUP, user_id: BOB, pledge_pnc_micros: 30_000_000, status: 'active' }],
    });
    const { env, supa } = ctx(db, { [GROUP]: 0, [BOB_SUB]: 0 });

    const view = await readGroupWallet(env, supa, GROUP);

    expect(view.poolMicros).toBe(0);
    expect(view.totalStakeMicros).toBe(0);
    const bob = view.members.find((m) => m.userId === BOB)!;
    expect(bob.pledgeMicros).toBe(30_000_000); // 认缴额度还在
    expect(bob.pledgeEffectiveMicros).toBe(0); // 但余额见底,生效 0
    expect(bob.stakeMicros).toBe(0);
  });
});
