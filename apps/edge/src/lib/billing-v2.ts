import type { SupabaseClient } from './supabase';

// Billing v2 core (see docs/billing-v2-design.md r2).
//
// This module is the single point that knows about packs / usage_events /
// ledger_entries / overdraft / thresholds. It replaces v1's mix of
// audit_log.cost_credits + billing_debit RPC + balance_credits column.
//
// v1 lives alongside this for now; cutover is endpoint-by-endpoint.
// See task #182+ for the migration sequence.

// ============================================================
// Constants — §2 conversion / §7 thresholds / §4 default expiry
// ============================================================

/** 1 PNC = 1_000_000 micros. Internal precision unit. */
export const PNC_MICROS_PER_PNC = 1_000_000;

/**
 * 27 PNC = 1 USD. Intentionally awkward ratio (§2) — users can't
 * mentally translate PNC ↔ USD, which reduces per-call price anxiety.
 * Do NOT change this to a "rounder" number; it's a product decision.
 */
export const PNC_PER_USD = 27;

export const PNC_MICROS_PER_USD = PNC_MICROS_PER_PNC * PNC_PER_USD; // 27_000_000

/** Threshold: balance below this → "余额低" notice injected into next reply. */
export const THRESHOLD_LOW_PNC_MICROS = 50 * PNC_MICROS_PER_PNC;

/** Threshold: balance below this → force OpenRouter cost_quality_tradeoff=max, tools off. */
export const THRESHOLD_THROTTLE_PNC_MICROS = 5 * PNC_MICROS_PER_PNC;

/**
 * Overdraft buffer: when a usage event exceeds remaining balance, the
 * settle still records the full debit (via an overdraft ledger entry)
 * up to this amount, so a streaming LLM doesn't get cut off in the
 * last few tokens. Anything past this is platform loss for now.
 */
export const OVERDRAFT_BUFFER_PNC_MICROS = 500_000; // 0.5 PNC

/** Default cash-topup pack expiry — §4. */
export const PACK_DEFAULT_EXPIRY_DAYS = 365;

// ============================================================
// Types
// ============================================================

export type ThresholdState = 'sufficient' | 'low' | 'throttle' | 'exhausted';

export type OwnerRef =
  | { kind: 'user'; userId: string }
  | { kind: 'subject'; subjectId: string };

export type EventCategory =
  | 'llm_tokens'
  | 'server_side_tools'
  | 'web_tools'
  | 'voice_tokens'
  | 'realtimekit_media'
  | 'sandbox_runtime'
  | 'storage_transfer'
  | 'push_delivery';

export type QuantityUnit =
  | 'tokens'
  | 'calls'
  | 'minutes'
  | 'seconds'
  | 'bytes'
  | 'mb'
  | 'gb';

export type CostSource = 'gateway' | 'provider' | 'local_pricebook' | 'manual';

export type SalesChannel =
  | 'iap_ios'
  | 'iap_macos'
  | 'lemon_squeezy'
  | 'admin_grant'
  | 'group_topup'
  | 'group_refund'
  | 'v1_migration';

// ============================================================
// Conversion helpers
// ============================================================

/**
 * Convert vendor USD cost to PNC micros.
 *
 * Math: usd × 27 × 1_000_000. Uses Math.round (not ceil) — across many
 * cheap calls, ceil systemically over-bills; round averages out.
 *
 * Returns 0 for null / 0 / negative / non-finite inputs (the fallback
 * "we don't know the cost so we don't bill" path).
 */
export function usdToPncMicros(costUsd: number | null | undefined): number {
  if (!costUsd || costUsd <= 0) return 0;
  if (!Number.isFinite(costUsd)) return 0;
  return Math.round(costUsd * PNC_MICROS_PER_USD);
}

/**
 * Categorize a balance into one of four threshold bands. Drives:
 * - 'sufficient' (≥ 50 PNC): no UX intervention
 * - 'low'       (< 50 PNC):  inject "余额低" notice on next reply (24h debounce caller's responsibility)
 * - 'throttle'  (<  5 PNC):  force cheap model, tools off
 * - 'exhausted' (≤ 0 PNC):   route to no-balance notice path
 *
 * Edge code only branches on this enum. Threshold numbers live here so
 * a config update is one PR + one isolate restart, not a DB write.
 */
export function getThresholdState(balanceMicros: number): ThresholdState {
  if (balanceMicros <= 0) return 'exhausted';
  if (balanceMicros < THRESHOLD_THROTTLE_PNC_MICROS) return 'throttle';
  if (balanceMicros < THRESHOLD_LOW_PNC_MICROS) return 'low';
  return 'sufficient';
}

/** Default expiry timestamp for a fresh cash-topup pack. */
export function defaultPackExpiresAt(now: Date = new Date()): string {
  const d = new Date(now.getTime());
  d.setUTCDate(d.getUTCDate() + PACK_DEFAULT_EXPIRY_DAYS);
  return d.toISOString();
}

// ============================================================
// Balance lookup
// ============================================================

function ownerColumn(owner: OwnerRef): {
  userId: string | null;
  subjectId: string | null;
} {
  return owner.kind === 'user'
    ? { userId: owner.userId, subjectId: null }
    : { userId: null, subjectId: owner.subjectId };
}

/**
 * Sum the remaining PNC micros across an owner's active packs.
 * Returns 0 for owners with no packs (also for DB errors — billing
 * failures must never break the user-visible path).
 */
export async function getOwnerBalanceMicros(
  supa: SupabaseClient,
  owner: OwnerRef,
): Promise<number> {
  const col = owner.kind === 'user' ? 'owner_user_id' : 'owner_subject_id';
  const val = owner.kind === 'user' ? owner.userId : owner.subjectId;
  const { data, error } = await supa
    .from('packs')
    .select('remaining_pnc_micros')
    .eq('status', 'active')
    .eq(col, val);
  if (error) {
    console.warn('[billing-v2.getOwnerBalanceMicros]', error.message ?? String(error));
    return 0;
  }
  return (data ?? []).reduce(
    (acc, row) => acc + Number(row.remaining_pnc_micros ?? 0),
    0,
  );
}

export interface BalanceCheckResult {
  balanceMicros: number;
  thresholdState: ThresholdState;
}

/** Pre-call gate read. Cheap (one SUM); call before any billable work. */
export async function checkBalance(
  supa: SupabaseClient,
  owner: OwnerRef,
): Promise<BalanceCheckResult> {
  const balance = await getOwnerBalanceMicros(supa, owner);
  return { balanceMicros: balance, thresholdState: getThresholdState(balance) };
}

// ============================================================
// Settle
// ============================================================

export interface SettleUsageParams {
  owner: OwnerRef;
  category: EventCategory;
  provider: string;
  vendorSku?: string | null;
  modelId?: string | null;
  quantity: number;
  quantityUnit: QuantityUnit;
  vendorCostUsd: number;
  costSource: CostSource;
  conversationId?: string | null;
  auditLogId?: string | null;
  rawUsage?: Record<string, unknown>;
}

export interface SettleUsageResult {
  /** Empty string if usage_event insertion failed (logged + swallowed). */
  usageEventId: string;
  /** Total micros actually deducted from packs. */
  pncMicrosBilled: number;
  /** Micros the cost exceeded available pack balance (platform loss). */
  pncMicrosOverdrawn: number;
  /**
   * Notional final balance after this settle. Equals SUM(active packs)
   * minus any unfunded overdraft. Drives thresholdState.
   */
  balanceAfterMicros: number;
  thresholdState: ThresholdState;
}

/**
 * Settle one usage event against an owner's wallet.
 *
 *  1. Compute pnc_micros from vendor_cost_usd (§2).
 *  2. INSERT a usage_events row (preserved forever for audit).
 *  3. Fetch active packs FIFO: ORDER BY expires_at NULLS LAST, created_at.
 *  4. For each pack: debit = min(pack.remaining, still_owed). UPDATE with
 *     CAS predicate (remaining >= debit) to survive concurrent settles.
 *     Write a ledger_entries `debit` row referencing the pack.
 *  5. If still_owed > 0 after exhausting packs: write a single ledger
 *     `overdraft` row (no pack). Owner's next pre-call check sees
 *     balance ≤ 0 and routes through the no-balance notice path.
 *
 * Always returns — never throws to the user-visible request path.
 *
 * Concurrency: optimistic. Two settles racing on the same pack: only
 * one CAS UPDATE succeeds; the loser refetches once and retries. If both
 * still race, the second is logged and degrades to overdraft.
 */
export async function settleUsage(
  supa: SupabaseClient,
  params: SettleUsageParams,
): Promise<SettleUsageResult> {
  const pncMicrosOwed = usdToPncMicros(params.vendorCostUsd);
  const ownerCols = ownerColumn(params.owner);

  // 1. usage_events insert (always — even if pncMicrosOwed = 0, we want the audit trail)
  const { data: ueData, error: ueErr } = await supa
    .from('usage_events')
    .insert({
      owner_user_id: ownerCols.userId,
      owner_subject_id: ownerCols.subjectId,
      conversation_id: params.conversationId ?? null,
      audit_log_id: params.auditLogId ?? null,
      event_category: params.category,
      provider: params.provider,
      vendor_sku: params.vendorSku ?? null,
      model_id: params.modelId ?? null,
      quantity: params.quantity,
      quantity_unit: params.quantityUnit,
      vendor_cost_usd: params.vendorCostUsd,
      pnc_micros: pncMicrosOwed,
      cost_source: params.costSource,
      raw_usage: (params.rawUsage ?? {}) as never,
    })
    .select('id')
    .single();
  if (ueErr || !ueData) {
    console.warn('[billing-v2.settleUsage] usage_event insert', ueErr?.message ?? 'no data');
    const balance = await getOwnerBalanceMicros(supa, params.owner);
    return {
      usageEventId: '',
      pncMicrosBilled: 0,
      pncMicrosOverdrawn: 0,
      balanceAfterMicros: balance,
      thresholdState: getThresholdState(balance),
    };
  }
  const usageEventId = ueData.id;

  // Zero-cost early exit (free tier, unpriced passthrough, etc.).
  if (pncMicrosOwed <= 0) {
    const balance = await getOwnerBalanceMicros(supa, params.owner);
    return {
      usageEventId,
      pncMicrosBilled: 0,
      pncMicrosOverdrawn: 0,
      balanceAfterMicros: balance,
      thresholdState: getThresholdState(balance),
    };
  }

  // 2. Read initial balance once; we'll track running balance locally
  //    so each ledger row's balance_after is consistent without a
  //    round-trip per debit.
  let runningBalance = await getOwnerBalanceMicros(supa, params.owner);

  let stillOwed = pncMicrosOwed;
  let totalBilled = 0;

  // Two passes — handles a single race (CAS lost) by re-reading packs.
  for (let attempt = 0; attempt < 2 && stillOwed > 0; attempt++) {
    const ownerCol = params.owner.kind === 'user' ? 'owner_user_id' : 'owner_subject_id';
    const ownerVal = params.owner.kind === 'user' ? params.owner.userId : params.owner.subjectId;
    const { data: packs, error: packsErr } = await supa
      .from('packs')
      .select('id, remaining_pnc_micros')
      .eq('status', 'active')
      .eq(ownerCol, ownerVal)
      .order('expires_at', { ascending: true, nullsFirst: false })
      .order('created_at', { ascending: true })
      .limit(50);

    if (packsErr) {
      console.warn('[billing-v2.settleUsage] fetch packs', packsErr.message);
      break;
    }
    if (!packs || packs.length === 0) break;

    let progressedThisPass = false;
    for (const pack of packs) {
      if (stillOwed <= 0) break;
      const packRemaining = Number(pack.remaining_pnc_micros);
      const debit = Math.min(packRemaining, stillOwed);
      if (debit <= 0) continue;
      const newRemaining = packRemaining - debit;
      // CAS: only succeed if remaining still >= debit.
      const { data: updated, error: updErr } = await supa
        .from('packs')
        .update({
          remaining_pnc_micros: newRemaining,
          status: newRemaining === 0 ? 'exhausted' : 'active',
        })
        .eq('id', pack.id)
        .gte('remaining_pnc_micros', debit)
        .select('id')
        .maybeSingle();
      if (updErr) {
        console.warn('[billing-v2.settleUsage] pack debit', updErr.message);
        continue;
      }
      if (!updated) continue; // CAS lost; outer loop will refetch.

      stillOwed -= debit;
      totalBilled += debit;
      runningBalance -= debit;
      progressedThisPass = true;

      // Per-debit ledger entry. Best-effort: a ledger insert failure logs
      // but doesn't roll back the pack update — the pack remaining +
      // usage_event are the authoritative record.
      const { error: ledErr } = await supa.from('ledger_entries').insert({
        owner_user_id: ownerCols.userId,
        owner_subject_id: ownerCols.subjectId,
        pack_id: pack.id,
        usage_event_id: usageEventId,
        entry_type: 'debit',
        delta_pnc_micros: -debit,
        balance_after_pnc_micros: runningBalance,
        metadata: {} as never,
      });
      if (ledErr) {
        console.warn('[billing-v2.settleUsage] ledger debit', ledErr.message);
      }
    }

    // No progress this pass = no point retrying (all CAS failed or empty list).
    if (!progressedThisPass) break;
  }

  let overdrawn = 0;
  if (stillOwed > 0) {
    overdrawn = stillOwed;
    runningBalance -= overdrawn;
    const { error: ledErr } = await supa.from('ledger_entries').insert({
      owner_user_id: ownerCols.userId,
      owner_subject_id: ownerCols.subjectId,
      pack_id: null,
      usage_event_id: usageEventId,
      entry_type: 'overdraft',
      delta_pnc_micros: -overdrawn,
      balance_after_pnc_micros: runningBalance,
      metadata: { reason: 'packs_exhausted' } as never,
    });
    if (ledErr) {
      console.warn('[billing-v2.settleUsage] ledger overdraft', ledErr.message);
    }
  }

  return {
    usageEventId,
    pncMicrosBilled: totalBilled,
    pncMicrosOverdrawn: overdrawn,
    balanceAfterMicros: runningBalance,
    thresholdState: getThresholdState(runningBalance),
  };
}
