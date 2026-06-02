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
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Env } from '../types';
import type { PolarClient } from './polar-client';
import { wallet } from './wallet-client';
import { computeShareNow } from './share-index';
import { recordCreditIn } from '../lib/billing-polar';

type Supa = SupabaseClient<any, any, any>;

// ============================================================
// Contribute(user → group)
// ============================================================

export interface ContributeParams {
  env: Env;
  supa: Supa;
  om: PolarClient;
  subjectId: string; // 群 subject(= Polar customer external_id)
  contributorUserId: string; // 出资人(= 其个人 Polar external_id)
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

  // 1. 余额门禁:转账不允许透支。
  const gate = await wallet.gate(env, contributorUserId);
  if (gate.balanceMicros < amount) return { ok: false, reason: 'insufficient_balance' };

  const cid = crypto.randomUUID();

  // 2. 扣出资人(usage:Polar + DO 缓存)。dedupeId 绑 contribution id,防重投。
  await om.reportUsage(contributorUserId, amount, {
    category: 'group_topup',
    dedupeId: `gtopup-out:${cid}`,
    metadata: { subject_id: subjectId },
  });
  await wallet.debit(env, contributorUserId, amount, {
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
    await recordCreditIn(supa, om, {
      subjectId: contributorUserId,
      kind: 'topup',
      source: 'group_refund',
      externalRef: rid,
      pncMicros: refundMicros,
      raw: { refunded_from_subject_id: subjectId },
    });
    await wallet.credit(env, contributorUserId, refundMicros);

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
  // 用户侧入账(credit-in 幂等 + DO 缓存)。
  await recordCreditIn(supa, om, {
    subjectId: userId,
    kind: 'topup',
    source: 'group_withdraw',
    externalRef: rid,
    pncMicros: withdrawn,
    raw: { withdrawn_from_subject_id: subjectId },
  });
  await wallet.credit(env, userId, withdrawn);

  return { withdrawnMicros: withdrawn };
}
