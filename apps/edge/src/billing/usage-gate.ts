// Pre-call usage gate + billing-owner resolution for the LLM path (计费 P2 Phase C).
//
// Source of truth for "who pays" + "may this turn run":
//   - resolveBillingSubjectId — group / temporary_group / crew conversations
//     bill against the conversation's responsible_subject_id (pool wallet);
//     everything else (1v1 / system) bills the initiating user. This is the
//     single owner resolver both the pre-call gate AND the post-call debit
//     (router.persistAuditMessage) route through, so gate-subject and
//     debit-subject can never drift.
//   - gateUsage — reads the subject's WalletDO cached balance (strong-
//     consistent, no DB round-trip) and maps it to a 4-band threshold:
//       sufficient (≥50 PNC) → run normally
//       low        (<50 PNC) → run, caller injects a "余额低" reminder
//       throttle   (<5  PNC) → run; caller SHOULD degrade (cheap model / no
//                              tools). See gate result `thresholdState`.
//       exhausted  (≤0 PNC)  → throw InsufficientBalanceError → 402 / no-balance
//                              copy path (model is never called).
//
// Only user-initiated paths gate. System cascades (title / lookback /
// bot_note) bill but never gate — they simply don't call gateUsage.
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import type { ThresholdState } from '../durable-objects/wallet';
import { InsufficientBalanceError } from '../lib/billing';
import { wallet } from './wallet-client';

export type { ThresholdState } from '../durable-objects/wallet';

export interface BillingTarget {
  /// The subject that pays. For groups/temp-groups/crew this is the
  /// responsible_subject_id; for 1v1/system it's the user id (subjects and
  /// user ids share the WalletDO key space — one DO per idFromName(id)).
  subjectId: string;
  /// 'subject' when resolved to a conversation responsibility subject;
  /// 'user' when it fell back to the initiating user. Audit metadata uses this.
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
  if (ctx.userId) return { subjectId: ctx.userId, kind: 'user' };
  return null;
}

export interface GateResult {
  subjectId: string;
  balanceMicros: number;
  thresholdState: ThresholdState;
}

/**
 * Pre-call gate. Resolves the billing subject, reads its WalletDO balance,
 * and HARD-STOPS (throws InsufficientBalanceError) when exhausted (≤0). For
 * low / throttle it returns the state so the caller can degrade — it does
 * NOT block. Call this BEFORE issuing an LLM request on a user-initiated
 * path; skip it for system cascades.
 *
 * When no billable subject can be resolved (system/bot-only turn) the gate
 * is a no-op pass — there's no wallet to read and nothing to charge.
 */
export async function gateUsage(
  env: Env,
  supa: SupabaseClient,
  ctx: { conversationId?: string | null; userId?: string | null },
): Promise<GateResult | null> {
  const target = await resolveBillingSubjectId(supa, ctx);
  if (!target) return null;
  const { balanceMicros, thresholdState } = await wallet.gate(env, target.subjectId);
  if (thresholdState === 'exhausted') {
    throw new InsufficientBalanceError(balanceMicros, 0);
  }
  return { subjectId: target.subjectId, balanceMicros, thresholdState };
}
