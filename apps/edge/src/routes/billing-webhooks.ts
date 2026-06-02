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
// ── Polar(新计费引擎)+ RevenueCat(iOS)入账 webhook ──
// 见 docs/superpowers/specs/2026-06-01-billing-engine-design.md
//     docs/superpowers/plans/2026-06-02-billing-p1-credit-in.md
import { validateEvent, WebhookVerificationError } from '@polar-sh/sdk/webhooks';
import { polarFromEnv } from '../billing/polar-client';
import { recordCreditIn, recordRefund } from '../lib/billing-polar';
import { resolvePack } from '../lib/billing-packs';
import { pncToMicros } from '../billing/pnc';
import { wallet } from '../billing/wallet-client';
import type { CustomerState } from '@polar-sh/sdk/models/components/customerstate.js';

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

// ============================================================
// Polar(web/Mac MoR)— order.paid 充值 / order.refunded 退款
// payload 字段路径已用官方 @polar-sh/sdk 生成类型核实(见下方 order.* 取值注释)。
// ============================================================

function polarClientOrNull(env: {
  POLAR_ACCESS_TOKEN?: string;
  POLAR_SERVER?: string;
  POLAR_PNC_METER_ID?: string;
}) {
  if (!env.POLAR_ACCESS_TOKEN || !env.POLAR_PNC_METER_ID) return null;
  return polarFromEnv(
    { POLAR_ACCESS_TOKEN: env.POLAR_ACCESS_TOKEN, POLAR_SERVER: env.POLAR_SERVER },
    env.POLAR_PNC_METER_ID,
  );
}

// 充值/退款后把 delta 实时推进 WalletDO 缓存(正=入账,负=退款扣减)。
// best-effort:webhook 必须 200,缓存失败由 WalletDO 的 alarm 稀疏对账纠偏。
async function pushWalletCredit(env: AppBindings['Bindings'], subjectId: string, pncMicros: number): Promise<void> {
  try {
    await wallet.credit(env, subjectId, pncMicros);
  } catch (e) {
    console.warn('[billing-webhook] wallet.credit push failed', subjectId, pncMicros, (e as Error)?.message);
  }
}

billingWebhookRoutes.post('/polar/webhook', async (c) => {
  const secret = c.env.POLAR_WEBHOOK_SECRET;
  if (!secret) return jsonError(c, 501, 'webhook_not_configured');
  const om = polarClientOrNull(c.env);
  if (!om) return jsonError(c, 501, 'polar_not_configured');

  const raw = await c.req.text();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let event: any;
  try {
    event = validateEvent(raw, Object.fromEntries(c.req.raw.headers), secret);
  } catch (e) {
    if (e instanceof WebhookVerificationError) return jsonError(c, 401, 'invalid_signature');
    throw e;
  }

  const supa = serviceClient(c.env);
  // 字段路径已用官方 SDK 生成类型核实(@polar-sh/sdk Order):
  //   order.customer.externalId(OrderCustomer.externalId?:string|null)、
  //   order.productId(顶层 string|null)/ order.product.id(OrderProduct.id)。
  const order = event?.data ?? {};
  const subjectId: string | undefined = order.customer?.externalId ?? undefined;
  const productId: string | undefined = order.productId ?? order.product?.id ?? undefined;

  if (event.type === 'order.paid' && subjectId && productId) {
    const pack = resolvePack('polar_checkout', productId);
    if (pack) {
      const pncMicros = pncToMicros(pack.pnc);
      const { applied } = await recordCreditIn(supa, om, {
        subjectId, kind: 'topup', source: 'polar_checkout', externalRef: String(order.id),
        pncMicros, markupSnapshot: pack.markupSnapshot, raw: order,
      });
      // 实时把入账推进 WalletDO 缓存(best-effort;失败由 alarm 对账纠偏,不可阻塞 200)。
      if (applied) await pushWalletCredit(c.env, subjectId, pncMicros);
    }
    return c.json({ ok: true });
  }
  if (event.type === 'order.refunded' && subjectId && productId) {
    const pack = resolvePack('polar_checkout', productId);
    if (pack) {
      const { clampedMicros } = await recordRefund(supa, om, {
        subjectId, source: 'polar_checkout', externalRef: `${order.id}:refund`,
        pncMicros: pncToMicros(pack.pnc), raw: order,
      });
      // 退款扣减实时推进缓存(负值);clampedMicros<=0 时无变动,跳过。
      if (clampedMicros > 0) await pushWalletCredit(c.env, subjectId, -clampedMicros);
    }
    return c.json({ ok: true });
  }

  // customer.state_changed:Polar 余额发生变化(含其它来源调整)→ 对齐 WalletDO 到绝对余额。
  // event.data 是官方 CustomerState(CustomerStateIndividual | CustomerStateTeam),
  // 二者均含 externalId(=我们的 subjectId)与 activeMeters: CustomerStateMeter[]。
  // CustomerStateMeter.balance = credited−consumed,单位与上报事件一致(=pnc_micros)。
  if (event.type === 'customer.state_changed') {
    const cs = event.data as CustomerState;
    const externalId = cs.externalId ?? undefined;
    const meter = cs.activeMeters.find((m) => m.meterId === c.env.POLAR_PNC_METER_ID);
    if (externalId && meter) {
      // best-effort:对齐绝对余额(DO 内会减去在途用量);失败由 alarm 对账纠偏。
      try {
        await wallet.applyAbsolute(c.env, externalId, meter.balance);
      } catch (e) {
        console.warn('[polar.state_changed] applyAbsolute failed', externalId, (e as Error)?.message);
      }
    }
    return c.json({ ok: true });
  }
  return c.json({ ok: true, ignored: event.type });
});

// ============================================================
// RevenueCat(iOS IAP)— NON_RENEWING_PURCHASE 充值 / CANCELLATION 退款 / REFUND_REVERSED 重发
// 鉴权:RevenueCat 无签名,只有共享密钥 Authorization 头 → 常量时间比对。
// ============================================================

billingWebhookRoutes.post('/revenuecat/webhook', async (c) => {
  const expected = c.env.REVENUECAT_WEBHOOK_AUTH;
  if (!expected) return jsonError(c, 501, 'webhook_not_configured');
  const got = c.req.header('authorization') ?? '';
  if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
    return jsonError(c, 401, 'invalid_auth');
  }
  const om = polarClientOrNull(c.env);
  if (!om) return jsonError(c, 501, 'polar_not_configured');

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let body: any;
  try {
    body = await c.req.json();
  } catch {
    return jsonError(c, 400, 'invalid_json');
  }
  const ev = body?.event;
  if (!ev) return jsonError(c, 400, 'invalid_json');

  const supa = serviceClient(c.env);
  const subjectId: string | undefined = ev.app_user_id;
  const pack = ev.product_id ? resolvePack('iap_ios', ev.product_id) : null;
  if (!subjectId || !pack) return c.json({ ok: true, skipped: 'no_subject_or_pack' });

  if (ev.type === 'NON_RENEWING_PURCHASE') {
    const pncMicros = pncToMicros(pack.pnc);
    const { applied } = await recordCreditIn(supa, om, {
      subjectId, kind: 'topup', source: 'iap_ios', externalRef: String(ev.transaction_id),
      pncMicros, markupSnapshot: pack.markupSnapshot, raw: ev,
    });
    if (applied) await pushWalletCredit(c.env, subjectId, pncMicros);
    return c.json({ ok: true });
  }
  if (ev.type === 'CANCELLATION') {
    const { clampedMicros } = await recordRefund(supa, om, {
      subjectId, source: 'iap_ios', externalRef: `${ev.transaction_id}:refund`,
      pncMicros: pncToMicros(pack.pnc), raw: ev,
    });
    if (clampedMicros > 0) await pushWalletCredit(c.env, subjectId, -clampedMicros);
    return c.json({ ok: true });
  }
  if (ev.type === 'REFUND_REVERSED') {
    const pncMicros = pncToMicros(pack.pnc);
    const { applied } = await recordCreditIn(supa, om, {
      subjectId, kind: 'topup', source: 'iap_ios', externalRef: `${ev.transaction_id}:rev`,
      pncMicros, markupSnapshot: pack.markupSnapshot, raw: ev,
    });
    if (applied) await pushWalletCredit(c.env, subjectId, pncMicros);
    return c.json({ ok: true });
  }
  return c.json({ ok: true, ignored: ev.type });
});

// 常量时间字符串比较(避免计时攻击)。
function timingSafeEqual(a: string, b: string): boolean {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
