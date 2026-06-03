import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import { capture } from './analytics';
import { AnalyticsEvent } from './track';
import {
  LEMON_SQUEEZY_DEFAULT_MARKUP,
  LEMON_SQUEEZY_NET_REVENUE_RATIO,
  issuePack,
  usdCentsToPncMicrosViaMarkup,
} from './billing-v2-pack';
import { processRefundEvent } from './billing-v2-refund';

// Lemon Squeezy webhook handler (see docs/billing-v2-design.md §10).
//
// LS sends each event with:
//   X-Signature: hex(HMAC-SHA256(secret, raw_body))
//   X-Event-Name: order_created | order_refunded | ...
//
// We verify the signature on raw bytes (NOT re-parsed JSON, which
// would lose key ordering / whitespace).
//
// Idempotency: every event references an `id` field on `data.attributes`
// (the order id). issuePack() uses it as external_purchase_id.

// ============================================================
// HMAC verification
// ============================================================

/** Hex-decode (case-insensitive). Returns null on malformed input. */
function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    const byte = parseInt(hex.slice(i, i + 2), 16);
    if (Number.isNaN(byte)) return null;
    out[i / 2] = byte;
  }
  return out;
}

/** Constant-time equality. Returns false for mismatched lengths. */
function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a[i] ^ b[i];
  return mismatch === 0;
}

/**
 * Verify the X-Signature header against the raw request body.
 * Returns true only on a match.
 */
export async function verifyLemonSqueezySignature(
  rawBody: Uint8Array,
  signatureHex: string,
  secret: string,
): Promise<boolean> {
  if (!signatureHex || !secret) return false;
  const expected = hexToBytes(signatureHex);
  if (!expected) return false;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, rawBody as BufferSource);
  return timingSafeEqual(new Uint8Array(sig), expected);
}

// ============================================================
// Payload shapes (a thin slice of LS's webhook envelope)
// ============================================================

/**
 * LS lets you attach arbitrary key/value pairs at checkout creation.
 * We'll set { user_id, subject_id? } there so the webhook can route
 * purchases to the right wallet. If absent we reject the event.
 */
export interface LemonSqueezyCustomData {
  user_id?: string;
  /** Optional — set when the user is funding a group subject directly. */
  subject_id?: string;
}

export interface LemonSqueezyWebhookEnvelope {
  meta?: {
    event_name?: string;
    custom_data?: LemonSqueezyCustomData;
  };
  data?: {
    type?: string;
    id?: string;
    attributes?: {
      status?: string;
      currency?: string;
      total_usd?: number; // cents
      identifier?: string;
      order_number?: number | string;
      [k: string]: unknown;
    };
  };
}

// ============================================================
// Event handlers
// ============================================================

export type LemonSqueezyHandlerResult =
  | { ok: true; action: 'issued' | 'duplicate' | 'refund_recorded' | 'ignored' }
  | { ok: false; status: number; reason: string };

export interface LemonSqueezyHandlerEnv {
  supa: SupabaseClient;
  env: Env;
  payload: LemonSqueezyWebhookEnvelope;
}

/** Top-level dispatch. Picks the handler for the X-Event-Name. */
export async function handleLemonSqueezyEvent(
  args: LemonSqueezyHandlerEnv,
): Promise<LemonSqueezyHandlerResult> {
  const event = args.payload.meta?.event_name ?? '';
  switch (event) {
    case 'order_created':
      return handleOrderCreated(args);
    case 'order_refunded':
      return handleOrderRefunded(args);
    default:
      // We deliberately don't 4xx on unknown events — LS will retry, and
      // they add new event types over time. Return ok so the webhook
      // queue drains.
      return { ok: true, action: 'ignored' };
  }
}

async function handleOrderCreated(
  args: LemonSqueezyHandlerEnv,
): Promise<LemonSqueezyHandlerResult> {
  const { supa, payload } = args;
  const attrs = payload.data?.attributes;
  const orderId = payload.data?.id;
  const status = attrs?.status;

  if (!orderId) {
    return { ok: false, status: 400, reason: 'missing_order_id' };
  }
  if (status !== 'paid') {
    // Some statuses (pending, failed, refunded-at-creation) shouldn't
    // mint a pack. Wait for the paid event.
    return { ok: true, action: 'ignored' };
  }

  const userId = payload.meta?.custom_data?.user_id;
  const subjectId = payload.meta?.custom_data?.subject_id;
  if (!userId && !subjectId) {
    return { ok: false, status: 400, reason: 'missing_wallet_target_in_custom_data' };
  }

  const totalUsdCents = typeof attrs?.total_usd === 'number' ? attrs.total_usd : 0;
  if (totalUsdCents <= 0) {
    return { ok: false, status: 400, reason: 'invalid_total_usd' };
  }

  const pncMicros = usdCentsToPncMicrosViaMarkup(
    totalUsdCents,
    LEMON_SQUEEZY_DEFAULT_MARKUP,
  );
  const netCents = Math.floor(totalUsdCents * LEMON_SQUEEZY_NET_REVENUE_RATIO);

  const owner = subjectId
    ? ({ kind: 'subject', subjectId } as const)
    : ({ kind: 'user', userId: userId as string } as const);

  const result = await issuePack({
    supa,
    owner,
    salesChannel: 'lemon_squeezy',
    pncMicros,
    externalPurchaseId: `ls:order:${orderId}`,
    grossPaidUsdCents: totalUsdCents,
    netRevenueUsdCents: netCents,
    salesMarkup: LEMON_SQUEEZY_DEFAULT_MARKUP,
    metadata: {
      ls_event: 'order_created',
      ls_order_identifier: attrs?.identifier ?? null,
      ls_order_number: attrs?.order_number ?? null,
      ls_currency: attrs?.currency ?? null,
    },
  });

  if (!result.ok) {
    return { ok: false, status: 500, reason: `issue_pack_failed:${result.reason}` };
  }
  if (result.created) {
    // Real new credit (idempotent replays return created:false). Awaited —
    // a webhook has no request executionCtx and can afford one extra fetch.
    // capture() never throws and no-ops when PostHog is unset.
    await capture(args.env, {
      distinctId: (userId ?? subjectId)!,
      event: AnalyticsEvent.TopupSucceeded,
      properties: {
        channel: 'lemon_squeezy',
        owner_kind: owner.kind,
        usd_cents: totalUsdCents,
        pnc_micros: pncMicros,
      },
    });
  }
  return { ok: true, action: result.created ? 'issued' : 'duplicate' };
}

async function handleOrderRefunded(
  args: LemonSqueezyHandlerEnv,
): Promise<LemonSqueezyHandlerResult> {
  const { supa, payload } = args;
  const orderId = payload.data?.id;
  const attrs = payload.data?.attributes;
  if (!orderId) {
    return { ok: false, status: 400, reason: 'missing_order_id' };
  }

  const externalRefundId = `ls:refund:${orderId}`;
  const refundAmountUsdCents =
    typeof attrs?.total_usd === 'number' ? attrs.total_usd : 0;

  // Find the original pack so the chargeback link is clear.
  const { data: pack } = await supa
    .from('packs')
    .select('id')
    .eq('external_purchase_id', `ls:order:${orderId}`)
    .maybeSingle();

  // Idempotency: refund_events has UNIQUE(source, external_refund_id).
  const { data: insRow, error: insErr } = await supa
    .from('refund_events')
    .insert({
      source: 'lemon_squeezy',
      external_refund_id: externalRefundId,
      pack_id: pack?.id ?? null,
      refund_amount_usd_cents: refundAmountUsdCents,
      consumed_pnc_micros_at_refund: 0,
      chargeback_loss_pnc_micros: 0,
      raw_payload: payload as never,
    })
    .select('id')
    .single();
  if (insErr) {
    if (insErr.code === '23505') {
      // Already received; idempotent retry. Refund processor / cron will
      // pick up any leftover work.
      return { ok: true, action: 'refund_recorded' };
    }
    return { ok: false, status: 500, reason: insErr.message };
  }

  // Eager-process the refund inline. The cron sweep (#187) catches any
  // rows that fail here (left with processed_at IS NULL).
  if (insRow) {
    await processRefundEvent({ supa, refundEventId: insRow.id });
  }
  return { ok: true, action: 'refund_recorded' };
}
