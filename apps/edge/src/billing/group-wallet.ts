// 群钱包 —— share-index 池模型重挂到 Polar(余额事实源)+ WalletDO(边缘缓存)。
// 设计:docs/superpowers/plans/2026-06-02-group-wallet-polar-rehome.md
//       docs/billing-v2-design.md §9(share-index DeFi 质押池模型)。
//
// 余额事实源 = Polar(群 subject = 一个 Polar customer,external_id = subjectId)。
// group_pools.total_remaining_pnc_micros 是公平性镜像 + share_index 衰减基数。
// group_contributions 记每笔注资的 share_index_at_join,退款时按
//   share_now = contributed × (当前 share_index / join 时 share_index)。
//
// 账目落点(关键,别记错):
//   - 注资 出资人侧 = usage(reportUsage + wallet.debit),不进 pnc_ledger。
//   - 注资 群侧     = credit-in(recordCreditIn 幂等)+ wallet.credit。
//   - 退款 群侧     = reduceCredits + 手写 pnc_ledger refund 行(不用 recordRefund:
//                     它按 ledger 可用夹,而 ledger 不含群消费,会超退)。
//   - 退款 用户侧   = credit-in(recordCreditIn 幂等)+ wallet.credit。
//
// 键的约定(别混):群主体 subjectId 本来就是 subjects.id;但
// group_contributions.contributor_user_id / group_pledges.user_id 存的是
// **auth user id**(外键指向 users)。凡是要碰某个成员的**个人钱包 / Polar
// customer / pnc_ledger** 的地方,都要先经 subject-key 解析成其 user_account
// subject id —— 直接拿 user id 去 wallet.* 会落到一个永远空的 DO。
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Env } from '../types';
import type { PolarClient } from './polar-client';
import { wallet } from './wallet-client';
import { computeShareNow } from './share-index';
import { recordCreditIn } from '../lib/billing-polar';
import {
  findUserWalletSubjectId,
  resolveSubjectUserId,
  resolveUserWalletSubjectId,
} from './subject-key';
import { billingEnabled } from '../lib/feature-flags';

type Supa = SupabaseClient<any, any, any>;

// ============================================================
// Contribute(user → group)
// ============================================================

export interface ContributeParams {
  env: Env;
  supa: Supa;
  om: PolarClient;
  subjectId: string; // 群 subject(= Polar customer external_id)
  contributorUserId: string; // 出资人的 **auth user id**(个人钱包键由 subject-key 解析)
  pncMicros: number;
}

export type ContributeResult =
  | { ok: true; contributionId: string; debitedMicros: number }
  | { ok: false; reason: 'insufficient_balance' | 'invalid_amount' | 'db_error'; message?: string };

/**
 * 把 PNC 从出资人钱包转入群钱包。
 * 顺序:门禁 → 扣出资人(usage)→ 池增 + 拿 join index → 记 contribution →
 *       群侧入账(credit)。任一 Polar 步失败由 WalletDO alarm 稀疏对账纠偏。
 */
export async function contributeToGroup(p: ContributeParams): Promise<ContributeResult> {
  const { env, supa, om, subjectId, contributorUserId } = p;
  const amount = Math.trunc(p.pncMicros);
  if (!Number.isFinite(amount) || amount <= 0) return { ok: false, reason: 'invalid_amount' };

  // 出资人的个人钱包键 = 其 user_account subject id(不是 auth user id)。
  const contributorSubjectId = await resolveUserWalletSubjectId(supa, contributorUserId);

  // 1. 余额门禁:转账不允许透支。
  const gate = await wallet.gate(env, contributorSubjectId);
  if (gate.balanceMicros < amount) return { ok: false, reason: 'insufficient_balance' };

  const cid = crypto.randomUUID();

  // 2. 扣出资人(usage:Polar + DO 缓存)。dedupeId 绑 contribution id,防重投。
  await om.reportUsage(contributorSubjectId, amount, {
    category: 'group_topup',
    dedupeId: `gtopup-out:${cid}`,
    metadata: { subject_id: subjectId },
  });
  await wallet.debit(env, contributorSubjectId, amount, {
    category: 'group_topup',
    dedupeId: `gtopup-out:${cid}`,
    meta: { subject_id: subjectId },
  });

  // 3. 池增 + 拿 join 时 share_index(原子 RPC)。
  const { data: joinIdxRaw, error: poolErr } = await supa.rpc('apply_group_contribution', {
    p_subject_id: subjectId,
    p_amount_micros: amount,
  });
  if (poolErr) return { ok: false, reason: 'db_error', message: poolErr.message };
  const shareIndexAtJoin = Number(joinIdxRaw ?? 1);

  // 4. 记 contribution(active)。
  const { error: contribErr } = await supa.from('group_contributions').insert({
    id: cid,
    subject_id: subjectId,
    contributor_user_id: contributorUserId,
    contributed_pnc_micros: amount,
    share_index_at_join: shareIndexAtJoin,
    status: 'active',
  });
  if (contribErr) return { ok: false, reason: 'db_error', message: contribErr.message };

  // 5. 群侧入账(credit-in 幂等 + Polar grant)+ DO 缓存。
  await recordCreditIn(supa, om, {
    subjectId,
    kind: 'topup',
    source: 'group_topup',
    externalRef: cid,
    pncMicros: amount,
    raw: { contributor_user_id: contributorUserId },
  });
  await wallet.credit(env, subjectId, amount);

  return { ok: true, contributionId: cid, debitedMicros: amount };
}

// ============================================================
// Refund a contributor(leave group)
// ============================================================

export interface RefundParams {
  env: Env;
  supa: Supa;
  om: PolarClient;
  subjectId: string;
  contributorUserId: string;
}

export type RefundResult =
  | { ok: true; refundedMicros: number; contributionsRefunded: number }
  | { ok: false; reason: 'no_contributions' | 'pool_missing' | 'db_error'; message?: string };

/**
 * 按当前份额把出资人在群里的钱退回其个人钱包。
 * share_now 已含历史消耗(share_index 衰减);再夹到 poolTotal(已被消费衰减)防超退。
 */
export async function refundContributorFromGroup(p: RefundParams): Promise<RefundResult> {
  const { env, supa, om, subjectId, contributorUserId } = p;

  // 1. 池状态。
  const { data: pool, error: poolErr } = await supa
    .from('group_pools')
    .select('total_remaining_pnc_micros, share_index')
    .eq('subject_id', subjectId)
    .maybeSingle();
  if (poolErr) return { ok: false, reason: 'db_error', message: poolErr.message };
  if (!pool) return { ok: false, reason: 'pool_missing' };
  const currentShareIndex = Number(pool.share_index);
  const poolTotal = Number(pool.total_remaining_pnc_micros);

  // 2. active 注资。
  const { data: contributions, error: contribErr } = await supa
    .from('group_contributions')
    .select('id, contributed_pnc_micros, share_index_at_join')
    .eq('subject_id', subjectId)
    .eq('contributor_user_id', contributorUserId)
    .eq('status', 'active');
  if (contribErr) return { ok: false, reason: 'db_error', message: contribErr.message };
  if (!contributions || contributions.length === 0) return { ok: false, reason: 'no_contributions' };

  // 3. share_now 合计,夹到池子。
  let shareNowTotal = 0;
  for (const c of contributions) {
    shareNowTotal += computeShareNow(
      Number(c.contributed_pnc_micros),
      Number(c.share_index_at_join),
      currentShareIndex,
    );
  }
  const refundMicros = Math.max(0, Math.min(shareNowTotal, poolTotal));
  const rid = crypto.randomUUID();

  if (refundMicros > 0) {
    // 4a. 群侧出账:Polar reduceCredits + 手写 pnc_ledger 审计行 + DO 缓存。
    //     不用 recordRefund(它按 ledger 可用夹,ledger 不含群消费会超退)。
    await supa.from('pnc_ledger').insert({
      subject_id: subjectId,
      kind: 'refund',
      source: 'group_refund',
      external_ref: rid,
      delta_pnc_micros: -refundMicros,
      raw: { contributor_user_id: contributorUserId },
    });
    await om.reduceCredits(subjectId, refundMicros, { source: 'group_refund', dedupeId: `grefund-out:${rid}` });
    await wallet.debit(env, subjectId, refundMicros, {
      category: 'group_refund',
      dedupeId: `grefund-out:${rid}`,
      meta: { contributor_user_id: contributorUserId },
    });

    // 4b. 用户侧入账(credit-in 幂等 + Polar grant)+ DO 缓存。
    //     键是出资人的 user_account subject(pnc_ledger 外键 + Polar external_id)。
    const contributorSubjectId = await resolveUserWalletSubjectId(supa, contributorUserId);
    await recordCreditIn(supa, om, {
      subjectId: contributorSubjectId,
      kind: 'topup',
      source: 'group_refund',
      externalRef: rid,
      pncMicros: refundMicros,
      raw: { refunded_from_subject_id: subjectId, contributor_user_id: contributorUserId },
    });
    await wallet.credit(env, contributorSubjectId, refundMicros);

    // 4c. 池减(share_index 不变)。
    await supa.rpc('apply_group_refund', { p_subject_id: subjectId, p_refund_micros: refundMicros });
  }

  // 5. 标记 contributions refunded(即使 refundMicros=0,也置 refunded:群已花光时退 0 好过卡 active)。
  const ids = contributions.map((c) => c.id as string);
  await supa
    .from('group_contributions')
    .update({ status: 'refunded', refunded_at: new Date().toISOString() })
    .in('id', ids);

  return { ok: true, refundedMicros: refundMicros, contributionsRefunded: ids.length };
}

// ============================================================
// Dissolve group
// ============================================================

export interface DissolveParams {
  env: Env;
  supa: Supa;
  om: PolarClient;
  subjectId: string;
}

/** 对所有 active 出资人各退一次,直到没有。bounded loop 防数据异常死循环。 */
export async function dissolveGroup(
  p: DissolveParams,
): Promise<{ ok: true; refundedContributors: number; totalRefundedMicros: number }> {
  const { env, supa, om, subjectId } = p;
  let refundedContributors = 0;
  let totalRefunded = 0;

  for (let i = 0; i < 1000; i++) {
    const { data: next } = await supa
      .from('group_contributions')
      .select('contributor_user_id')
      .eq('subject_id', subjectId)
      .eq('status', 'active')
      .limit(1)
      .maybeSingle();
    if (!next) break;

    const r = await refundContributorFromGroup({
      env,
      supa,
      om,
      subjectId,
      contributorUserId: next.contributor_user_id as string,
    });
    if (!r.ok) break;
    refundedContributors += 1;
    totalRefunded += r.refundedMicros;
  }

  return { ok: true, refundedContributors, totalRefundedMicros: totalRefunded };
}

// ============================================================
// Spend decay(群消费后衰减 share_index)
// ============================================================

/** 群消费后衰减 share_index(仅群 subject 调用)。best-effort,失败只 log,由对账纠偏。 */
export async function applyGroupSpendDecay(
  supa: Supa,
  subjectId: string,
  spendMicros: number,
): Promise<void> {
  const micros = Math.trunc(spendMicros);
  if (!Number.isFinite(micros) || micros <= 0) return;
  try {
    await supa.rpc('apply_group_pool_spend', { p_subject_id: subjectId, p_spend_micros: micros });
  } catch (e) {
    console.warn('[group-wallet] applyGroupSpendDecay failed', subjectId, (e as Error)?.message);
  }
}

// ============================================================
// 认缴(pledge)读写
// ============================================================

export interface Pledge {
  userId: string;
  pledgeMicros: number;
}

/** 群的所有有效认缴(status=active)。 */
export async function getActivePledges(supa: Supa, subjectId: string): Promise<Pledge[]> {
  const { data } = await supa
    .from('group_pledges')
    .select('user_id, pledge_pnc_micros')
    .eq('subject_id', subjectId)
    .eq('status', 'active');
  return (data ?? []).map((r) => ({
    userId: r.user_id as string,
    pledgeMicros: Number(r.pledge_pnc_micros),
  }));
}

/** 设/改认缴额度;amountMicros<=0 视为撤销(status=revoked, 额度 0)。 */
export async function setPledge(
  supa: Supa,
  subjectId: string,
  userId: string,
  amountMicros: number,
): Promise<void> {
  const micros = Math.max(0, Math.trunc(amountMicros));
  await supa.from('group_pledges').upsert(
    {
      subject_id: subjectId,
      user_id: userId,
      pledge_pnc_micros: micros,
      status: micros > 0 ? 'active' : 'revoked',
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'subject_id,user_id' },
  );
}

// ============================================================
// 链式退款:上游退款命中已注资进群的钱 → 从群冲减(不返还用户)
// ============================================================

/**
 * 用户被上游(Apple/Polar)退款 amount 时,先把其在各群的当前份额冲减(最多冲到
 * 各群 share_now 合计):缩该用户在群里的 contributions + 减群池 + reduceCredits 群 Polar +
 * 群侧 pnc_ledger 审计。**不返还用户**(用户拿的是上游现金)。等价于"该用户撤回了自己那份",
 * 对其他群成员公平(share_index 不变)。返回实际从群冲掉的额度,调用方用 amount−clawed 退个人。
 * 这堵住"注资进群→退购买款→群仍留额度"的漏洞(billing-v2-design §9 链式退款)。
 */
export async function clawbackFromGroups(
  env: Env,
  supa: Supa,
  om: PolarClient,
  contributorSubjectId: string,
  amountMicros: number,
): Promise<{ clawedMicros: number }> {
  let remaining = Math.trunc(amountMicros);
  if (!Number.isFinite(remaining) || remaining <= 0) return { clawedMicros: 0 };

  // 调用方(Polar / RevenueCat webhook)手上是**个人 subject id**,而
  // group_contributions.contributor_user_id 存的是 auth user id —— 反查一跳。
  // 查不到就没法确定注资归属:返回 0 并留日志,由调用方全额退个人(不静默漏冲)。
  const userId = await resolveSubjectUserId(supa, contributorSubjectId);
  if (!userId) {
    console.error('[group-wallet.clawbackFromGroups] subject → user unresolved', contributorSubjectId);
    return { clawedMicros: 0 };
  }

  const { data: rows } = await supa
    .from('group_contributions')
    .select('subject_id')
    .eq('contributor_user_id', userId)
    .eq('status', 'active');
  const groups = [...new Set((rows ?? []).map((r) => r.subject_id as string))];

  let clawed = 0;
  for (const g of groups) {
    if (remaining <= 0) break;
    const { data } = await supa.rpc('apply_partial_withdraw', {
      p_subject_id: g,
      p_user_id: userId,
      p_amount_micros: remaining,
    });
    const reduced = Number(data ?? 0);
    if (reduced <= 0) continue;
    const rid = crypto.randomUUID();
    await supa.from('pnc_ledger').insert({
      subject_id: g,
      kind: 'refund',
      source: 'chargeback_clawback',
      external_ref: rid,
      delta_pnc_micros: -reduced,
      raw: { contributor_user_id: userId },
    });
    await om.reduceCredits(g, reduced, { source: 'chargeback_clawback', dedupeId: `cb:${rid}` });
    await wallet.debit(env, g, reduced, { category: 'chargeback_clawback', dedupeId: `cb-do:${rid}` });
    clawed += reduced;
    remaining -= reduced;
  }
  return { clawedMicros: clawed };
}

// ============================================================
// 分账份额 + 群消费分账(实缴池衰减 + 认缴个人钱包直扣)
// ============================================================

export interface PledgeStake {
  /** 成员的 auth user id(group_pledges.user_id;用于 meta / dedupe / 展示)。 */
  userId: string;
  /** 该成员的个人钱包键(user_account subject id;wallet.* 只认这个)。 */
  subjectId: string;
  stakeMicros: number;
}

export interface GroupStakes {
  poolStake: number; // 实缴池余额(群 WalletDO)
  pledgeStakes: PledgeStake[]; // 认缴 min(pledge, 余额)
  total: number; // S = 池 + Σ认缴
}

/** 读群当前分账份额:实缴池(群 WalletDO 余额) + 各认缴成员 min(pledge, 个人余额)。 */
export async function resolveGroupStakes(
  env: Env,
  supa: Supa,
  subjectId: string,
): Promise<GroupStakes> {
  const poolGate = await wallet.gate(env, subjectId);
  const poolStake = Math.max(0, poolGate.balanceMicros);
  const pledges = await getActivePledges(supa, subjectId);
  const pledgeStakes: PledgeStake[] = [];
  for (const pl of pledges) {
    // 认缴份额读的是该成员的个人钱包 —— 键是其 user_account subject。解析不到
    // 就把这份认缴当 0(该成员不参与分摊)并报错级日志:不猜键、不静默用 user id。
    const memberSubjectId = await findUserWalletSubjectId(supa, pl.userId);
    if (!memberSubjectId) {
      console.error('[group-wallet.resolveGroupStakes] pledge member subject unresolved', subjectId, pl.userId);
      continue;
    }
    const g = await wallet.gate(env, memberSubjectId);
    const stake = Math.max(0, Math.min(pl.pledgeMicros, g.balanceMicros));
    if (stake > 0) pledgeStakes.push({ userId: pl.userId, subjectId: memberSubjectId, stakeMicros: stake });
  }
  const total = poolStake + pledgeStakes.reduce((s, x) => s + x.stakeMicros, 0);
  return { poolStake, pledgeStakes, total };
}

// ============================================================
// 群钱包视图(只读,供 iOS 群钱包页 GET /v1/group-subjects/:id/wallet)
// ============================================================

export interface MemberWalletView {
  userId: string;
  /** 该成员实缴的当前可取出份额(share_now 合计,micros)。 */
  contributionShareNowMicros: number;
  /** 该成员设置的认缴额度(active,micros;0 = 未认缴)。 */
  pledgeMicros: number;
  /** 当前生效认缴 = min(pledge, 个人余额)(micros)。余额见底 → 0。 */
  pledgeEffectiveMicros: number;
  /** 该成员总份额 = 实缴 share_now + 生效认缴(micros)。 */
  stakeMicros: number;
}

export interface GroupWalletView {
  /** 实缴池余额(群 WalletDO,micros)。 */
  poolMicros: number;
  /** S = 池 + Σ生效认缴(micros)。分摊/占比的分母。 */
  totalStakeMicros: number;
  /** 有实缴或认缴的成员明细(无份额成员不在此列;占比 = stake/S)。 */
  members: MemberWalletView[];
}

/**
 * 读群钱包当前快照:实缴池余额 + S + 每个有份额成员的实缴 share_now / 认缴 / 总份额。
 * 复用 resolveGroupStakes(池 + 生效认缴 + S);实缴 share_now 按 group_contributions
 * 当前 share_index 折算。纯读,不动钱。调用方用 service client(跨成员读)。
 */
export async function readGroupWallet(
  env: Env,
  supa: Supa,
  subjectId: string,
): Promise<GroupWalletView> {
  const stakes = await resolveGroupStakes(env, supa, subjectId);

  // 当前 share_index(实缴池折算基数)。
  const { data: pool } = await supa
    .from('group_pools')
    .select('share_index')
    .eq('subject_id', subjectId)
    .maybeSingle();
  const idxNow = Number(pool?.share_index ?? 1);

  // 各出资人实缴 share_now 合计。
  const { data: contribs } = await supa
    .from('group_contributions')
    .select('contributor_user_id, contributed_pnc_micros, share_index_at_join')
    .eq('subject_id', subjectId)
    .eq('status', 'active');
  const shareNowByUser = new Map<string, number>();
  for (const c of contribs ?? []) {
    const uid = c.contributor_user_id as string;
    const sn = computeShareNow(
      Number(c.contributed_pnc_micros),
      Number(c.share_index_at_join),
      idxNow,
    );
    shareNowByUser.set(uid, (shareNowByUser.get(uid) ?? 0) + sn);
  }

  // 设置的认缴额度(含余额见底、生效份额为 0 的;resolveGroupStakes 只含生效>0 的)。
  const setPledges = await getActivePledges(supa, subjectId);
  const setPledgeByUser = new Map(setPledges.map((p) => [p.userId, p.pledgeMicros]));
  const effByUser = new Map(stakes.pledgeStakes.map((s) => [s.userId, s.stakeMicros]));

  const userIds = new Set<string>([...shareNowByUser.keys(), ...setPledgeByUser.keys()]);
  const members: MemberWalletView[] = [];
  for (const uid of userIds) {
    const csn = shareNowByUser.get(uid) ?? 0;
    const eff = effByUser.get(uid) ?? 0;
    members.push({
      userId: uid,
      contributionShareNowMicros: csn,
      pledgeMicros: setPledgeByUser.get(uid) ?? 0,
      pledgeEffectiveMicros: eff,
      stakeMicros: csn + eff,
    });
  }

  return {
    poolMicros: stakes.poolStake,
    totalStakeMicros: stakes.total,
    members,
  };
}

export interface SettleGroupParams {
  env: Env;
  supa: Supa;
  subjectId: string;
  spendMicros: number;
  category: string;
  dedupeId: string;
  meta?: Record<string, unknown>;
}

/**
 * 群消费分账:实缴池摊 X·池/S(扣群 WalletDO + 衰减 share_index),
 * 认缴成员各摊 X·份额/S(实时直扣其个人 WalletDO,个人 DO 串行权威)。
 * 无任何份额(total<=0)→ 整笔记群池(透支兜底,与无认缴时一致)。
 */
export async function settleGroupSpend(p: SettleGroupParams): Promise<void> {
  const { env, supa, subjectId } = p;
  // Kill-switch: billing off (default) → don't decay the pool / debit members.
  if (!(await billingEnabled(env))) return;
  const spend = Math.trunc(p.spendMicros);
  if (!Number.isFinite(spend) || spend <= 0) return;

  const { poolStake, pledgeStakes, total } = await resolveGroupStakes(env, supa, subjectId);
  if (total <= 0) {
    await wallet.debit(env, subjectId, spend, { category: p.category, dedupeId: p.dedupeId, meta: p.meta });
    await applyGroupSpendDecay(supa, subjectId, spend);
    return;
  }

  const poolPortion = Math.round((spend * poolStake) / total);
  if (poolPortion > 0) {
    await wallet.debit(env, subjectId, poolPortion, { category: p.category, dedupeId: p.dedupeId, meta: p.meta });
    await applyGroupSpendDecay(supa, subjectId, poolPortion);
  }
  for (const m of pledgeStakes) {
    const portion = Math.round((spend * m.stakeMicros) / total);
    if (portion <= 0) continue;
    try {
      await wallet.debit(env, m.subjectId, portion, {
        category: p.category,
        // dedupe 键沿用 userId,格式不变(改了会让在途重投绕过幂等重复扣款)。
        dedupeId: `${p.dedupeId}:pledge:${m.userId}`,
        meta: { ...(p.meta ?? {}), group_subject_id: subjectId, via: 'pledge' },
      });
    } catch (e) {
      console.warn('[group-wallet] pledge debit failed', subjectId, m.userId, (e as Error)?.message);
    }
  }
}

// ============================================================
// 部分取出(实缴,随时、可部分)
// ============================================================

export interface WithdrawParams {
  env: Env;
  supa: Supa;
  om: PolarClient;
  subjectId: string;
  userId: string;
  amountMicros: number;
}

/**
 * 从实缴池退回 amount(≤ 当前 share_now)给成员个人钱包,留在群里。
 * apply_partial_withdraw 原子缩 contributions + 减池(share_index 不变),返回实退额。
 */
export async function withdrawFromGroup(p: WithdrawParams): Promise<{ withdrawnMicros: number }> {
  const { env, supa, om, subjectId, userId } = p;
  const amount = Math.trunc(p.amountMicros);
  if (!Number.isFinite(amount) || amount <= 0) return { withdrawnMicros: 0 };

  const { data } = await supa.rpc('apply_partial_withdraw', {
    p_subject_id: subjectId,
    p_user_id: userId,
    p_amount_micros: amount,
  });
  const withdrawn = Number(data ?? 0);
  if (withdrawn <= 0) return { withdrawnMicros: 0 };

  const rid = crypto.randomUUID();
  // 群侧出账:Polar 群减 + 手写审计 + DO 缓存(不用 recordRefund:ledger 不含群消费会超退)。
  await supa.from('pnc_ledger').insert({
    subject_id: subjectId,
    kind: 'refund',
    source: 'group_withdraw',
    external_ref: rid,
    delta_pnc_micros: -withdrawn,
    raw: { contributor_user_id: userId },
  });
  await om.reduceCredits(subjectId, withdrawn, { source: 'group_withdraw', dedupeId: `gwd-out:${rid}` });
  await wallet.debit(env, subjectId, withdrawn, { category: 'group_withdraw', dedupeId: `gwd-out:${rid}` });
  // 用户侧入账(credit-in 幂等 + DO 缓存)。键是取出人的 user_account subject。
  const userSubjectId = await resolveUserWalletSubjectId(supa, userId);
  await recordCreditIn(supa, om, {
    subjectId: userSubjectId,
    kind: 'topup',
    source: 'group_withdraw',
    externalRef: rid,
    pncMicros: withdrawn,
    raw: { withdrawn_from_subject_id: subjectId, contributor_user_id: userId },
  });
  await wallet.credit(env, userSubjectId, withdrawn);

  return { withdrawnMicros: withdrawn };
}
