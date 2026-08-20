import { Hono } from 'hono';
import { jsonError } from '../lib/http-error';
import { serviceClient } from '../lib/supabase';
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
import { clawbackFromGroups } from '../billing/group-wallet';
import { capture } from '../lib/analytics';
import { AnalyticsEvent } from '../lib/track';
import { safeWaitUntil } from '../lib/safe-wait-until';
import type { CustomerState } from '@polar-sh/sdk/models/components/customerstate.js';

// Billing credit-in webhooks (see docs/superpowers/specs/2026-06-01-billing-engine-design.md).
//
// Two routes:
//   POST /v1/billing/polar/webhook       — Polar (web/Mac MoR) server-to-server
//   POST /v1/billing/revenuecat/webhook  — RevenueCat (iOS IAP) server-to-server

export const billingWebhookRoutes = new Hono<AppBindings>();

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

// 充值成功后上报 PostHog topup_succeeded(#228)。原先挂在已删除的 lemon/iap
// webhook 上,现重新挂到 Polar / RevenueCat 入账成功路径。只在 applied(首次入账,
// 非幂等重放)时上报,避免重发 webhook 重复计数。fire-and-forget、无 PII:
// distinctId=subjectId(=用户/主体 id),properties 只放 channel/额度/pack。
// capture() 在 POSTHOG 未配置时是 no-op,自带吞错,绝不阻塞 webhook 的 200。
function trackTopupSucceeded(
  c: Parameters<typeof jsonError>[0],
  args: { subjectId: string; channel: string; pncMicros: number; packId: string },
): void {
  safeWaitUntil(
    c,
    capture(c.env, {
      distinctId: args.subjectId,
      event: AnalyticsEvent.TopupSucceeded,
      properties: {
        channel: args.channel,
        owner_kind: 'user',
        pnc_micros: args.pncMicros,
        pack_id: args.packId,
      },
    }),
  );
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
    const pack = await resolvePack(c.env, 'polar_checkout', productId);
    if (pack) {
      const pncMicros = pncToMicros(pack.pnc);
      const { applied } = await recordCreditIn(supa, om, {
        subjectId, kind: 'topup', source: 'polar_checkout', externalRef: String(order.id),
        pncMicros, markupSnapshot: pack.markupSnapshot, raw: order,
      });
      // 实时把入账推进 WalletDO 缓存(best-effort;失败由 alarm 对账纠偏,不可阻塞 200)。
      if (applied) {
        await pushWalletCredit(c.env, subjectId, pncMicros);
        trackTopupSucceeded(c, { subjectId, channel: 'polar_checkout', pncMicros, packId: productId });
      }
    }
    return c.json({ ok: true });
  }
  if (event.type === 'order.refunded' && subjectId && productId) {
    const pack = await resolvePack(c.env, 'polar_checkout', productId);
    if (pack) {
      const intended = pncToMicros(pack.pnc);
      // 链式退款:先从该用户已注资进群的份额冲减(防"注资进群→退款→群留额度"),
      // 再退个人剩余。clawback 已自行 reduceCredits 群 + 推进群 DO 缓存。
      const { clawedMicros } = await clawbackFromGroups(c.env, supa, om, subjectId, intended);
      const personal = Math.max(0, intended - clawedMicros);
      if (personal > 0) {
        const { clampedMicros } = await recordRefund(supa, om, {
          subjectId, source: 'polar_checkout', externalRef: `${order.id}:refund`,
          pncMicros: personal, raw: order,
        });
        if (clampedMicros > 0) await pushWalletCredit(c.env, subjectId, -clampedMicros);
      }
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

/** RC 侧 supabase 查询的最小面(便于单测注入 mock)。 */
export interface RcSubjectLookup {
  from(table: string): {
    select(cols: string): {
      eq(col: string, v: string): {
        eq(col: string, v: string): { maybeSingle(): Promise<{ data: { id: string } | null }> }
        maybeSingle(): Promise<{ data: { id: string } | null }>
      }
    }
  }
}

/**
 * RC `app_user_id` → subject id。iOS Telemetry.identify 绑的是 **auth.users.id**
 * (Account.id),不是 subject id —— 先查 user_account subject 映射;查不到再按
 * subject id 直用兜底(防未来 app 侧改绑成 subject id)。匿名 id 直接放弃。
 */
export async function resolveRcSubjectId(
  supa: RcSubjectLookup,
  appUserId: unknown,
): Promise<string | undefined> {
  if (typeof appUserId !== 'string' || !appUserId || appUserId.startsWith('$RCAnonymousID:')) {
    return undefined;
  }
  const { data: byUser } = await supa
    .from('subjects').select('id')
    .eq('user_id', appUserId).eq('kind', 'user_account')
    .maybeSingle();
  if (byUser?.id) return byUser.id;
  const { data: bySubject } = await supa
    .from('subjects').select('id').eq('id', appUserId).maybeSingle();
  return bySubject?.id ?? undefined;
}

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
  // 结构收窄:PostgrestBuilder 是 thenable 而非 Promise,与 mock 接缝的最小面不严格相容。
  const subjectId = await resolveRcSubjectId(supa as unknown as RcSubjectLookup, ev.app_user_id);
  const pack = ev.product_id ? await resolvePack(c.env, 'iap_ios', String(ev.product_id)) : null;
  if (!subjectId || !pack) return c.json({ ok: true, skipped: 'no_subject_or_pack' });

  if (ev.type === 'NON_RENEWING_PURCHASE') {
    const pncMicros = pncToMicros(pack.pnc);
    const { applied } = await recordCreditIn(supa, om, {
      subjectId, kind: 'topup', source: 'iap_ios', externalRef: String(ev.transaction_id),
      pncMicros, markupSnapshot: pack.markupSnapshot, raw: ev,
    });
    if (applied) {
      await pushWalletCredit(c.env, subjectId, pncMicros);
      trackTopupSucceeded(c, { subjectId, channel: 'iap_ios', pncMicros, packId: String(ev.product_id) });
    }
    return c.json({ ok: true });
  }
  if (ev.type === 'CANCELLATION') {
    const intended = pncToMicros(pack.pnc);
    // 链式退款:先冲群份额再退个人剩余(同 Polar 路径)。
    const { clawedMicros } = await clawbackFromGroups(c.env, supa, om, subjectId, intended);
    const personal = Math.max(0, intended - clawedMicros);
    if (personal > 0) {
      const { clampedMicros } = await recordRefund(supa, om, {
        subjectId, source: 'iap_ios', externalRef: `${ev.transaction_id}:refund`,
        pncMicros: personal, raw: ev,
      });
      if (clampedMicros > 0) await pushWalletCredit(c.env, subjectId, -clampedMicros);
    }
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
