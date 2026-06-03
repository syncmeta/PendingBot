// 送(signup welcome)/兑换(redeem)统一走 Polar 的入账助手。
//
// 两者都:fetch email → ensureCustomer(没付过钱的用户在 Polar 没 customer)→
// recordCreditIn(幂等账本 + grantCredits 负值事件)→ 同步 WalletDO 缓存。
//
// 只在 BILLING_ENABLED 时与 Polar 交互:预发布(kill-switch 关)时不建 customer、
// 不发额度、不烧 sandbox。见 docs/superpowers/specs/2026-06-03-polar-grant-redeem-orphan-purge.md。
import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import { polarFromEnv } from '../billing/polar-client';
import { recordCreditIn } from './billing-polar';
import { wallet } from '../billing/wallet-client';
import { billingEnabled } from './feature-flags';
import { MICROS_PER_PNC } from '../billing/pnc';

/** 新用户注册 welcome 赠送额(PNC)。35 PNC ≈ $1.30(= 旧 3500 PND 赠送值原样迁移)。 */
export const SIGNUP_BONUS_PNC = 35;
/** PND(v1 兑换码单位)→ PNC micros:$1 = 2700 PND = 27 PNC ⇒ micros = PND × 10_000。 */
export const PND_TO_PNC_MICROS = 10_000;

function polarReady(env: Env): boolean {
  return Boolean(env.POLAR_ACCESS_TOKEN && env.POLAR_PNC_METER_ID);
}

function polar(env: Env) {
  return polarFromEnv(
    { POLAR_ACCESS_TOKEN: env.POLAR_ACCESS_TOKEN as string, POLAR_SERVER: env.POLAR_SERVER },
    env.POLAR_PNC_METER_ID as string,
  );
}

async function fetchEmail(supa: SupabaseClient, userId: string): Promise<string | null> {
  const { data } = await supa.from('users').select('email').eq('id', userId).maybeSingle();
  const email = (data as { email?: string | null } | null)?.email;
  return typeof email === 'string' && email.length > 0 ? email : null;
}

/**
 * 新用户 welcome 赠送(幂等)。仅 BILLING_ENABLED + Polar 配置齐时种 Polar 余额。
 * 幂等键 = pnc_ledger unique(source='signup', external_ref='signup:'+userId);先 guard
 * 查在,避免每次调用都打 Polar。须传 **service client**(写 pnc_ledger / 读 email)。
 * 永不抛:赠送是 best-effort,失败仅 log,不破坏调用它的请求(如 /me)。
 */
export async function grantSignupBonus(
  env: Env,
  svcSupa: SupabaseClient,
  userId: string,
): Promise<void> {
  if (!billingEnabled(env) || !polarReady(env)) return;
  const externalRef = `signup:${userId}`;
  try {
    const { data: existing } = await svcSupa
      .from('pnc_ledger')
      .select('id')
      .eq('subject_id', userId)
      .eq('source', 'signup')
      .eq('external_ref', externalRef)
      .maybeSingle();
    if (existing) return; // 已发过
    const email = await fetchEmail(svcSupa, userId);
    if (!email) return; // 没邮箱建不了 customer;下次再试
    const micros = SIGNUP_BONUS_PNC * MICROS_PER_PNC;
    const om = polar(env);
    await om.ensureCustomer(userId, email);
    const r = await recordCreditIn(svcSupa, om, {
      subjectId: userId,
      kind: 'admin',
      source: 'signup',
      externalRef,
      pncMicros: micros,
    });
    if (r.applied) await wallet.credit(env, userId, micros).catch(() => undefined);
  } catch (err) {
    console.warn('[billing-grant.grantSignupBonus] failed (best-effort)', (err as Error)?.message);
  }
}

/**
 * 兑换码入账 → Polar。调用方先用 user-scoped client 跑 billing_redeem RPC(原子校验+标记
 * used,返 {credits(PND), code_id}),再用本函数把额度发到用户 Polar customer。
 * 须传 **service client**(写 pnc_ledger / 读 email)。返回到账的 PNC micros。
 * Polar 未配置时只换算不入账(返 micros),便于本地/预发布。
 */
export async function creditRedemptionToPolar(
  env: Env,
  svcSupa: SupabaseClient,
  userId: string,
  codeId: string,
  creditsPnd: number,
): Promise<number> {
  const micros = Math.max(0, Math.trunc(creditsPnd)) * PND_TO_PNC_MICROS;
  if (micros <= 0 || !polarReady(env)) return micros;
  const email = await fetchEmail(svcSupa, userId);
  const om = polar(env);
  if (email) await om.ensureCustomer(userId, email);
  await recordCreditIn(svcSupa, om, {
    subjectId: userId,
    kind: 'redemption',
    source: 'redemption',
    externalRef: codeId,
    pncMicros: micros,
  });
  await wallet.credit(env, userId, micros).catch(() => undefined);
  return micros;
}
