// Pre-call usage gate + billing-owner resolution for the LLM path (计费 P2 Phase C).
//
// Source of truth for "who pays" + "may this turn run":
//   - resolveBillingSubjectId — group / temporary_group / crew conversations
//     bill against the conversation's responsible_subject_id (pool wallet);
//     everything else (1v1 / system) bills the initiating user. This is the
//     single owner resolver both the pre-call gate AND the post-call debit
//     (router.persistAuditMessage) route through, so gate-subject and
//     debit-subject can never drift.
//   - gateConversation — reads the subject's available balance (个人=WalletDO
//     缓存余额;群=实缴池+认缴聚合) and HARD-STOPS when exhausted (≤0 PNC):
//     returns an InsufficientBalanceError (不抛,便于并行 promise 拼装) →
//     402 / no-balance copy path (model is never called). 读失败 fail-open。
//
// Only user-initiated paths gate. System cascades (title / lookback /
// bot_note) bill but never gate — they simply don't call gateConversation.
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import type { ThresholdState } from '../durable-objects/wallet';
import { thresholdOf } from '../durable-objects/wallet';
import { InsufficientBalanceError } from '../lib/billing';
import { billingEnabled } from '../lib/feature-flags';
import { wallet } from './wallet-client';
import { resolveUserWalletSubjectId } from './subject-key';
import { resolveGroupStakes } from './group-wallet';

export type { ThresholdState } from '../durable-objects/wallet';

export interface BillingTarget {
  /// The subject that pays — **always a `pendingbot.subjects.id`**. Groups /
  /// temp-groups / crew use the conversation's responsible_subject_id; 1v1 /
  /// system resolve the initiating user to their user_account subject
  /// (billing/subject-key.ts). Never an auth user id: 入账被 pnc_ledger 的外键
  /// 钉死在 subjects.id,门禁用 user id 就会落到另一个空 WalletDO。
  subjectId: string;
  /// 'subject' when resolved to a conversation responsibility subject;
  /// 'user' when it fell back to the initiating user's own subject. Audit
  /// metadata uses this, and 群/个人 的扣费路径按它分叉。
  kind: 'subject' | 'user';
}

/**
 * Resolve the wallet subject a turn bills against. Preserves the v2
 * targeting semantics router.persistAuditMessage used pre-WalletDO:
 *
 *   group           → conversations.responsible_subject_id (pool wallet)
 *   temporary_group / crew
 *                   → temporary_group_meta.responsible_subject_id
 *                     (the immutable responsibility subject; design §9)
 *   anything else + userId
 *                   → the initiating user (1v1 / system)
 *
 * Returns null only when neither a conversation subject nor a userId is
 * available (a system/bot-only turn with no billable owner — left unbilled).
 * 抛 `WalletSubjectUnresolvedError` when 有 userId 但解析不出其 user_account
 * subject —— 调用方须显式 fail-open 并记日志,**不许**回退成 user id。
 *
 * Note the two-source split is deliberate: conversations.responsible_subject_id
 * is backfilled from the conv's own user_id for 1v1s, so for temp-group/crew
 * the authoritative responsibility subject lives in temporary_group_meta.
 */
export async function resolveBillingSubjectId(
  supa: SupabaseClient,
  ctx: { conversationId?: string | null; userId?: string | null },
): Promise<BillingTarget | null> {
  if (ctx.conversationId) {
    const { data } = await supa
      .from('conversations')
      .select('conversation_type, responsible_subject_id')
      .eq('id', ctx.conversationId)
      .maybeSingle();
    const type = data?.conversation_type;
    if (type === 'group') {
      const sid = data?.responsible_subject_id;
      if (typeof sid === 'string' && sid.length > 0) {
        return { subjectId: sid, kind: 'subject' };
      }
    } else if (type === 'temporary_group' || type === 'crew') {
      const { data: meta } = await supa
        .from('temporary_group_meta')
        .select('responsible_subject_id')
        .eq('conversation_id', ctx.conversationId)
        .maybeSingle();
      const sid = meta?.responsible_subject_id;
      if (typeof sid === 'string' && sid.length > 0) {
        return { subjectId: sid, kind: 'subject' };
      }
    }
    // Group-shaped conv with no responsibility subject set: fall through to
    // the initiating user rather than leaving the turn ungated/unbilled.
  }
  if (ctx.userId) {
    return { subjectId: await resolveUserWalletSubjectId(supa, ctx.userId), kind: 'user' };
  }
  return null;
}

/**
 * 主体可用额:个人 = 其 WalletDO 余额;群 = 实缴池 + Σ认缴成员 min(pledge, 余额)。
 * 群路径要读全群 pledge + 各成员余额,**须传 service-role client**(认缴 RLS 仅本人可读)。
 */
export async function availableForSubject(
  env: Env,
  supa: SupabaseClient,
  target: BillingTarget,
): Promise<{ balanceMicros: number; thresholdState: ThresholdState }> {
  if (target.kind === 'user') {
    const g = await wallet.gate(env, target.subjectId);
    return { balanceMicros: g.balanceMicros, thresholdState: g.thresholdState };
  }
  const { total } = await resolveGroupStakes(env, supa, target.subjectId);
  return { balanceMicros: total, thresholdState: thresholdOf(total) };
}

/**
 * 群感知前置门禁:解析计费主体(群=池+认缴聚合,个人=自己),exhausted 返回
 * InsufficientBalanceError(不抛,便于并行 promise 拼装),否则 null。读失败 fail-open。
 * **群路径须传 service client**。系统级级联不调本函数(只对用户发起路径)。
 */
export async function gateConversation(
  env: Env,
  supa: SupabaseClient,
  ctx: { conversationId?: string | null; userId?: string | null },
): Promise<InsufficientBalanceError | null> {
  // Kill-switch: billing off (default) → never block.
  if (!(await billingEnabled(env))) return null;
  try {
    const target = await resolveBillingSubjectId(supa, ctx);
    if (!target) return null;
    const avail = await availableForSubject(env, supa, target);
    if (avail.thresholdState === 'exhausted') {
      return new InsufficientBalanceError(avail.balanceMicros, 0);
    }
    return null;
  } catch (e) {
    // 含主体解析失败:明确 fail-open(放行)+ **报错级**日志。静默当 0 余额
    // 就是这次计费事故的形态,不许再出现。
    console.error('[gateConversation] fail-open', ctx.userId ?? null, (e as Error)?.message);
    return null;
  }
}
