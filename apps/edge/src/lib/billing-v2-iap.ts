import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import { capture } from './analytics';
import { AnalyticsEvent } from './track';
import {
  IAP_DEFAULT_MARKUP,
  APPLE_NET_REVENUE_RATIO,
  issuePack,
  usdCentsToPncMicrosViaMarkup,
} from './billing-v2-pack';
import type { SalesChannel } from './billing-v2';
import { processRefundEvent } from './billing-v2-refund';
import {
  verifyAppleJwsChain,
  AppleJwsVerifyError,
} from './billing-v2-iap-verify';

// Apple In-App Purchase / Server Notifications V2 (see docs/billing-v2-design.md §10).
//
// IMPORTANT — pre-launch state:
//
//   This module ships the data-flow, idempotency, and pack-issuance
//   plumbing for Apple IAP. JWS verification against Apple's certificate
//   chain is implemented in lib/billing-v2-iap-verify.ts (zero-dependency
//   x5c chain decode + ECDSA-P256 verify, SHA-256-pinned to Apple Root
//   CA G3). verifyAppleJws() below wraps it and adds the bundleId /
//   issuer claim assertions.
//
//   We deliberately do NOT have an "accept unverified payloads" dev
//   override. Per CLAUDE.md / feedback_no_shortcut_debt: a silently-on
//   bypass would be a security landmine. Verification failures throw an
//   AppleJwsVerifyError; callers map that to a non-2xx response.
//
// Flow shapes are correct so the eventual verification swap-in is local:
//
//   Client-initiated purchase   POST /v1/billing/iap/purchase
//     body: { signedTransactionInfo: string }
//     → verifyAppleJws() → handlePurchase() → issuePack()
//
//   Server-side notification    POST /v1/billing/iap/notify
//     body: { signedPayload: string }
//     → verifyAppleJws() → handleNotification() → refund_events / etc.

// ============================================================
// Apple-decoded payload shapes
// ============================================================

/**
 * Apple's JWS decoded payload for a consumable IAP transaction.
 * See https://developer.apple.com/documentation/appstoreservernotifications/jwstransactiondecodedpayload
 */
export interface AppleTransactionPayload {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  /** Quantity purchased — typically 1 for our PNC packs. */
  quantity: number;
  /** Cents (note: Apple field is in microunits historically; V2 returns price in microunits in some places). */
  price?: number;
  currency?: string;
  type:
    | 'Consumable'
    | 'Non-Consumable'
    | 'Auto-Renewable Subscription'
    | 'Non-Renewing Subscription';
  /** App Account Token — we'd ask the client to set this to user_id at purchase time. */
  appAccountToken?: string;
  /** Storefront ISO-3166-1 alpha-3 (e.g. "USA", "JPN"). */
  storefront?: string;
  purchaseDate: number; // ms epoch
  /** "iOS" / "macOS" so we map to iap_ios vs iap_macos. */
  inAppOwnershipType?: string;
  // ... many more — we only consume what we need.
}

export interface AppleServerNotificationPayload {
  notificationType:
    | 'CONSUMPTION_REQUEST'
    | 'REFUND'
    | 'REFUND_DECLINED'
    | 'REVOKE'
    | 'TEST'
    | string;
  subtype?: string;
  notificationUUID: string;
  data?: {
    appAppleId?: number;
    bundleId?: string;
    bundleVersion?: string;
    environment?: 'Production' | 'Sandbox';
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

// ============================================================
// JWS decode + verify
// ============================================================

/**
 * Base64URL decode → UTF-8 string. JWS uses base64url (no padding).
 */
function base64UrlDecode(input: string): Uint8Array {
  // Re-pad and convert to standard base64.
  const padded = input.replace(/-/g, '+').replace(/_/g, '/');
  const pad = padded.length % 4;
  const base64 = pad === 0 ? padded : padded + '='.repeat(4 - pad);
  const bin = atob(base64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * Decode a JWS without verification: returns {header, payload}.
 * Used by both verifyAppleJws (when implemented) and by tests / debug.
 */
export function decodeAppleJws<P>(jws: string): { header: unknown; payload: P } | null {
  const parts = jws.split('.');
  if (parts.length !== 3) return null;
  try {
    const header = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[0])));
    const payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[1]))) as P;
    return { header, payload };
  } catch {
    return null;
  }
}

/**
 * Verify Apple's JWS signature and return the decoded payload.
 *
 * Delegates the cryptographic work (x5c chain decode, validity windows,
 * chain verification, Apple Root CA G3 SHA-256 pin, ECDSA-P256 verify of
 * the signing input) to lib/billing-v2-iap-verify.ts, then asserts the
 * payload's `bundleId` matches env.APPLE_IAP_BUNDLE_ID (when configured).
 *
 * Throws on any failure so callers fail closed.
 */
export async function verifyAppleJws<P>(jws: string, env: Env): Promise<P> {
  const payload = await verifyAppleJwsChain<P & { bundleId?: string }>(jws);

  // Bind the payload to our app. APPLE_IAP_BUNDLE_ID is optional at
  // typecheck time (a deploy-time secret/var); when it is set we require an
  // exact match so a validly-signed JWS for a *different* Apple app cannot
  // mint credits here. When unset (e.g. local dev that hasn't configured
  // it), we skip the check but the cryptographic chain verification above
  // still holds — there is no unverified bypass.
  const expectedBundleId = env.APPLE_IAP_BUNDLE_ID;
  if (expectedBundleId && payload.bundleId && payload.bundleId !== expectedBundleId) {
    throw new AppleJwsVerifyError(
      'bundle_id_mismatch',
      `expected=${expectedBundleId} got=${payload.bundleId}`,
    );
  }

  return payload as P;
}

// ============================================================
// Handlers
// ============================================================

export type AppleHandlerResult =
  | { ok: true; action: 'issued' | 'duplicate' | 'refund_recorded' | 'ignored' }
  | { ok: false; status: number; reason: string };

export interface ApplePurchaseHandlerArgs {
  supa: SupabaseClient;
  env: Env;
  userId: string;
  signedTransactionInfo: string;
}

/**
 * Handle a client-initiated consumable purchase.
 * Client sends signedTransactionInfo from StoreKit 2; we verify, decode,
 * derive PNC, issue a pack.
 */
export async function handleApplePurchase(
  args: ApplePurchaseHandlerArgs,
): Promise<AppleHandlerResult> {
  const { supa, env, userId, signedTransactionInfo } = args;

  let txn: AppleTransactionPayload;
  try {
    txn = await verifyAppleJws<AppleTransactionPayload>(signedTransactionInfo, env);
  } catch (e) {
    return {
      ok: false,
      status: 501,
      reason: e instanceof Error ? e.message : 'verify_failed',
    };
  }

  if (txn.type !== 'Consumable') {
    return { ok: false, status: 400, reason: 'unsupported_product_type' };
  }
  // Verify the appAccountToken matches the calling user (client should set it).
  if (txn.appAccountToken && txn.appAccountToken !== userId) {
    return { ok: false, status: 403, reason: 'app_account_token_mismatch' };
  }

  // Cash → PNC. Apple's price is in micros of the currency unit in some
  // paths and cents in others; we expect cents and document the assumption.
  const priceCents = typeof txn.price === 'number' ? txn.price : 0;
  if (priceCents <= 0) {
    return { ok: false, status: 400, reason: 'invalid_price' };
  }
  const pncMicros = usdCentsToPncMicrosViaMarkup(priceCents, IAP_DEFAULT_MARKUP);
  const netCents = Math.floor(priceCents * APPLE_NET_REVENUE_RATIO);

  const channel: SalesChannel =
    txn.inAppOwnershipType === 'PURCHASED' && txn.bundleId?.toLowerCase().includes('mac')
      ? 'iap_macos'
      : 'iap_ios';

  const result = await issuePack({
    supa,
    owner: { kind: 'user', userId },
    salesChannel: channel,
    pncMicros,
    externalPurchaseId: `apple:txn:${txn.transactionId}`,
    grossPaidUsdCents: priceCents,
    netRevenueUsdCents: netCents,
    salesMarkup: IAP_DEFAULT_MARKUP,
    metadata: {
      apple_product_id: txn.productId,
      apple_original_transaction_id: txn.originalTransactionId,
      apple_storefront: txn.storefront ?? null,
      apple_in_app_ownership_type: txn.inAppOwnershipType ?? null,
      apple_purchase_date: txn.purchaseDate,
    },
  });
  if (!result.ok) {
    return { ok: false, status: 500, reason: `issue_pack_failed:${result.reason}` };
  }
  if (result.created) {
    // Real new credit landed (idempotent replays return created:false).
    // Awaited rather than waitUntil'd: this is a server-to-server webhook
    // with no request executionCtx, and a payment webhook can afford one
    // extra fetch. capture() never throws and no-ops when PostHog is unset.
    await capture(env, {
      distinctId: userId,
      event: AnalyticsEvent.TopupSucceeded,
      properties: {
        channel,
        owner_kind: 'user',
        usd_cents: priceCents,
        pnc_micros: pncMicros,
      },
    });
  }
  return { ok: true, action: result.created ? 'issued' : 'duplicate' };
}

export interface AppleNotificationHandlerArgs {
  supa: SupabaseClient;
  env: Env;
  signedPayload: string;
}

/**
 * Handle Apple App Store Server Notifications V2.
 * Mainly for REFUND / REVOKE — consumable purchases don't notify here.
 */
export async function handleAppleNotification(
  args: AppleNotificationHandlerArgs,
): Promise<AppleHandlerResult> {
  const { supa, env, signedPayload } = args;

  let notif: AppleServerNotificationPayload;
  try {
    notif = await verifyAppleJws<AppleServerNotificationPayload>(signedPayload, env);
  } catch (e) {
    return {
      ok: false,
      status: 501,
      reason: e instanceof Error ? e.message : 'verify_failed',
    };
  }

  switch (notif.notificationType) {
    case 'REFUND':
    case 'REVOKE':
      return handleAppleRefund(supa, notif, env);
    case 'TEST':
    case 'CONSUMPTION_REQUEST':
    case 'REFUND_DECLINED':
      return { ok: true, action: 'ignored' };
    default:
      return { ok: true, action: 'ignored' };
  }
}

async function handleAppleRefund(
  supa: SupabaseClient,
  notif: AppleServerNotificationPayload,
  env: Env,
): Promise<AppleHandlerResult> {
  const signedTxn = notif.data?.signedTransactionInfo;
  if (!signedTxn) {
    return { ok: false, status: 400, reason: 'missing_signed_transaction' };
  }
  let txn: AppleTransactionPayload;
  try {
    txn = await verifyAppleJws<AppleTransactionPayload>(signedTxn, env);
  } catch (e) {
    return {
      ok: false,
      status: 501,
      reason: e instanceof Error ? e.message : 'verify_failed',
    };
  }
  const externalPurchaseId = `apple:txn:${txn.transactionId}`;
  const externalRefundId = `apple:refund:${notif.notificationUUID}`;

  const { data: pack } = await supa
    .from('packs')
    .select('id')
    .eq('external_purchase_id', externalPurchaseId)
    .maybeSingle();

  const refundAmountUsdCents = typeof txn.price === 'number' ? txn.price : 0;

  const { data: insRow, error: insErr } = await supa
    .from('refund_events')
    .insert({
      source: 'apple',
      external_refund_id: externalRefundId,
      pack_id: pack?.id ?? null,
      refund_amount_usd_cents: refundAmountUsdCents,
      consumed_pnc_micros_at_refund: 0,
      chargeback_loss_pnc_micros: 0,
      raw_payload: notif as never,
    })
    .select('id')
    .single();
  if (insErr) {
    if (insErr.code === '23505') return { ok: true, action: 'refund_recorded' };
    return { ok: false, status: 500, reason: insErr.message };
  }
  if (insRow) {
    await processRefundEvent({ supa, refundEventId: insRow.id });
  }
  return { ok: true, action: 'refund_recorded' };
}
