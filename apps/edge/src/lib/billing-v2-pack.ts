import type { SupabaseClient } from './supabase';
import {
  PNC_MICROS_PER_USD,
  defaultPackExpiresAt,
  getOwnerBalanceMicros,
  type OwnerRef,
  type SalesChannel,
} from './billing-v2';

// Pack issuance (see docs/billing-v2-design.md §3, §4, §10).
//
// All channels that produce a new pack (IAP, Lemon Squeezy, admin grant,
// v1 migration, group_refund — group_topup goes through billing-v2-group)
// funnel through issuePack(). It enforces:
//
//   - external_purchase_id idempotency (webhooks retry; safe to replay)
//   - sales_markup_snapshot per pack (so future markup changes don't
//     touch historic balances)
//   - default 1-year expiry unless caller overrides (NULL for long-term)
//   - matching credit ledger entry
//
// Markup is NOT applied here — issuePack takes both the gross/net cash
// figures AND the pre-computed PNC count. The webhook handler is
// responsible for the cash-→-PNC conversion via the channel's markup.

// ============================================================
// Default markups (per channel)
// ============================================================
//
// These are PRE-LAUNCH PLACEHOLDERS. Real numbers are decided per
// channel at launch and recorded in each pack's sales_markup_snapshot,
// so changing these later does not affect already-issued packs.
//
// Math: `pnc_micros = (gross_paid_usd / sales_markup) × PNC_MICROS_PER_USD`
// (lower markup = more PNC per dollar = better for user).
//
// Apple takes 30% so net = gross × 0.7. LS takes 5% + payment processing
// (~2.9% + 30c) so net ≈ gross × 0.92. The doc says markup is computed on
// GROSS (the user's perception) — net just becomes platform-margin
// accounting and is stored on the pack for finance audit.

/** Apple IAP (iOS + macOS). Conservative default — Apple cut already 30%. */
export const IAP_DEFAULT_MARKUP = 2.0;
/** Lemon Squeezy (Mac App Store-external + Web). Smaller cut, smaller markup. */
export const LEMON_SQUEEZY_DEFAULT_MARKUP = 1.5;
/** Admin grant / v1 migration: no markup concept. */
export const ZERO_MARKUP = 1.0;

/** Apple keeps roughly 30% on consumables. */
export const APPLE_NET_REVENUE_RATIO = 0.7;
/** Lemon Squeezy + Stripe combined cut, ballpark. Real number lives in LS dashboard. */
export const LEMON_SQUEEZY_NET_REVENUE_RATIO = 0.92;

// ============================================================
// Pack issuance helpers
// ============================================================

export interface IssuePackParams {
  supa: SupabaseClient;
  owner: OwnerRef;
  salesChannel: SalesChannel;
  pncMicros: number;
  /** Webhook idempotency key. NULL for admin_grant / v1_migration / group_refund. */
  externalPurchaseId?: string | null;
  grossPaidUsdCents?: number | null;
  netRevenueUsdCents?: number | null;
  salesMarkup?: number | null;
  /** Override default expiry. Pass `null` explicitly for never-expiring packs. */
  expiresAt?: string | null;
  metadata?: Record<string, unknown>;
}

export type IssuePackResult =
  | { ok: true; packId: string; created: true }
  | { ok: true; packId: string; created: false; reason: 'already_issued' }
  | { ok: false; reason: 'invalid_amount' | 'db_error'; message?: string };

/**
 * Create a new pack and write the matching credit ledger entry.
 *
 * Idempotency: if `external_purchase_id` is non-null and a pack already
 * exists with that id, returns `{created:false}` with the existing pack id.
 * The DB-side UNIQUE INDEX on packs.external_purchase_id is the source
 * of truth; the pre-check race-window only matters for log clarity.
 */
export async function issuePack(params: IssuePackParams): Promise<IssuePackResult> {
  const {
    supa,
    owner,
    salesChannel,
    pncMicros,
    externalPurchaseId,
    grossPaidUsdCents,
    netRevenueUsdCents,
    salesMarkup,
    expiresAt,
    metadata,
  } = params;

  if (!Number.isFinite(pncMicros) || pncMicros < 0) {
    return { ok: false, reason: 'invalid_amount' };
  }

  // Idempotency pre-check (cheap, avoids a noisy duplicate-key error in logs).
  if (externalPurchaseId) {
    const { data: existing } = await supa
      .from('packs')
      .select('id')
      .eq('external_purchase_id', externalPurchaseId)
      .maybeSingle();
    if (existing) {
      return { ok: true, packId: existing.id, created: false, reason: 'already_issued' };
    }
  }

  // Default expiry: 1 year. Pass null explicitly for long-term packs.
  const resolvedExpiresAt =
    expiresAt === undefined ? defaultPackExpiresAt() : expiresAt;

  const ownerUserId = owner.kind === 'user' ? owner.userId : null;
  const ownerSubjectId = owner.kind === 'subject' ? owner.subjectId : null;

  const { data: pack, error: packErr } = await supa
    .from('packs')
    .insert({
      owner_user_id: ownerUserId,
      owner_subject_id: ownerSubjectId,
      initial_pnc_micros: pncMicros,
      remaining_pnc_micros: pncMicros,
      expires_at: resolvedExpiresAt,
      status: 'active',
      sales_channel: salesChannel,
      external_purchase_id: externalPurchaseId ?? null,
      gross_paid_usd_cents: grossPaidUsdCents ?? null,
      net_revenue_usd_cents: netRevenueUsdCents ?? null,
      sales_markup_snapshot: salesMarkup ?? null,
      metadata: (metadata ?? {}) as never,
    })
    .select('id')
    .single();

  if (packErr || !pack) {
    // 23505 = unique_violation on packs_external_purchase_id_uidx → idempotency hit
    if (packErr?.code === '23505' && externalPurchaseId) {
      const { data: existing } = await supa
        .from('packs')
        .select('id')
        .eq('external_purchase_id', externalPurchaseId)
        .maybeSingle();
      if (existing) {
        return { ok: true, packId: existing.id, created: false, reason: 'already_issued' };
      }
    }
    return { ok: false, reason: 'db_error', message: packErr?.message };
  }

  // Credit ledger.
  const newBalance = await getOwnerBalanceMicros(supa, owner);
  await supa.from('ledger_entries').insert({
    owner_user_id: ownerUserId,
    owner_subject_id: ownerSubjectId,
    pack_id: pack.id,
    usage_event_id: null,
    entry_type: 'credit',
    delta_pnc_micros: pncMicros,
    balance_after_pnc_micros: newBalance,
    metadata: {
      sales_channel: salesChannel,
      external_purchase_id: externalPurchaseId ?? null,
      ...(metadata ?? {}),
    } as never,
  });

  return { ok: true, packId: pack.id, created: true };
}

// ============================================================
// USD → PNC conversion (sales side)
// ============================================================

/**
 * Convert a USD payment amount into PNC micros via a sales markup.
 *
 * Per §3: `pnc_micros = (usd / markup) × 27_000_000`. Higher markup =
 * fewer PNC per dollar (more platform margin). Truncates to int micros
 * via floor — a tiny rounding favors the platform on each sale (the
 * dual of the favorable-to-user round on usage settle).
 */
export function usdCentsToPncMicrosViaMarkup(
  usdCents: number,
  markup: number,
): number {
  if (!Number.isFinite(usdCents) || usdCents <= 0) return 0;
  if (!Number.isFinite(markup) || markup <= 0) return 0;
  return Math.floor((usdCents / 100 / markup) * PNC_MICROS_PER_USD);
}
