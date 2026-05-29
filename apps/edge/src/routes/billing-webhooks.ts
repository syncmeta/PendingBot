import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import { serviceClient } from '../lib/supabase';
import {
  handleLemonSqueezyEvent,
  verifyLemonSqueezySignature,
  type LemonSqueezyWebhookEnvelope,
} from '../lib/billing-v2-lemon';
import {
  handleApplePurchase,
  handleAppleNotification,
} from '../lib/billing-v2-iap';
import type { AppBindings } from '../types';

// Billing v2 webhook + purchase endpoints (see docs/billing-v2-design.md §10).
//
// Three routes:
//   POST /v1/billing/lemonsqueezy/webhook  — LS server-to-server
//   POST /v1/billing/iap/purchase          — iOS client-initiated (user-auth)
//   POST /v1/billing/iap/notify            — Apple ASN V2 server-to-server
//
// Apple endpoints currently return 501 because JWS verification isn't
// implemented yet — see lib/billing-v2-iap.ts header. The data path is
// wired so enabling verification is a one-line change in that file.

export const billingWebhookRoutes = new Hono<AppBindings>();

// Client-auth IAP purchase requires a Supabase session.
billingWebhookRoutes.use('/iap/purchase', requireSession());

// ============================================================
// Lemon Squeezy
// ============================================================

billingWebhookRoutes.post('/lemonsqueezy/webhook', async (c) => {
  const secret = c.env.LEMON_SQUEEZY_WEBHOOK_SECRET;
  if (!secret) {
    return jsonError(c, 501, 'webhook_not_configured', {
      message: 'LEMON_SQUEEZY_WEBHOOK_SECRET is not set',
    });
  }
  const signature = c.req.header('x-signature') ?? '';
  if (!signature) {
    return jsonError(c, 401, 'missing_signature');
  }
  const rawBody = new Uint8Array(await c.req.arrayBuffer());
  const ok = await verifyLemonSqueezySignature(rawBody, signature, secret);
  if (!ok) {
    return jsonError(c, 401, 'invalid_signature');
  }
  let payload: LemonSqueezyWebhookEnvelope;
  try {
    payload = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return jsonError(c, 400, 'invalid_json');
  }
  const supa = serviceClient(c.env);
  const result = await handleLemonSqueezyEvent({ supa, env: c.env, payload });
  if (!result.ok) {
    return jsonError(c, result.status as 400 | 401 | 500 | 501, 'webhook_error', {
      message: result.reason,
    });
  }
  return c.json({ ok: true, action: result.action });
});

// ============================================================
// Apple IAP — client-initiated consumable purchase
// ============================================================

billingWebhookRoutes.post('/iap/purchase', async (c) => {
  const userId = c.var.userId!;
  let body: { signedTransactionInfo?: string };
  try {
    body = await c.req.json();
  } catch {
    return jsonError(c, 400, 'invalid_json');
  }
  if (!body.signedTransactionInfo || typeof body.signedTransactionInfo !== 'string') {
    return jsonError(c, 400, 'missing_signed_transaction_info');
  }
  const supa = serviceClient(c.env);
  const result = await handleApplePurchase({
    supa,
    env: c.env,
    userId,
    signedTransactionInfo: body.signedTransactionInfo,
  });
  if (!result.ok) {
    return jsonError(c, result.status as 400 | 401 | 403 | 500 | 501, 'iap_purchase_failed', {
      message: result.reason,
    });
  }
  return c.json({ ok: true, action: result.action });
});

// ============================================================
// Apple Server Notifications V2 — server-initiated
// ============================================================

billingWebhookRoutes.post('/iap/notify', async (c) => {
  let body: { signedPayload?: string };
  try {
    body = await c.req.json();
  } catch {
    return jsonError(c, 400, 'invalid_json');
  }
  if (!body.signedPayload || typeof body.signedPayload !== 'string') {
    return jsonError(c, 400, 'missing_signed_payload');
  }
  const supa = serviceClient(c.env);
  const result = await handleAppleNotification({
    supa,
    env: c.env,
    signedPayload: body.signedPayload,
  });
  if (!result.ok) {
    return jsonError(c, result.status as 400 | 500 | 501, 'apple_notification_failed', {
      message: result.reason,
    });
  }
  return c.json({ ok: true, action: result.action });
});
