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
import { resolveUserWalletSubjectId } from '../billing/subject-key';
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
 * 邮箱规范化(与 DB 的 pendingbot.normalize_email 同口径):lowercase + 去 plus-tag;
 * Gmail/Googlemail 另去点号并统一域。用于把别名折叠成同一身份做 welcome-bonus 去重。
 *
 * 之所以在 edge 也实现一份(而非每次 RPC 调 DB 函数):认领走 pnc_ledger /
 * welcome_bonus_grants 已经一次写,这里只是算 key,纯字符串处理,无需多一次往返。
 * 两边逻辑必须保持一致 —— 改一处必改另一处(DB 函数是真理源,见同名迁移)。
 */
export function normalizeEmail(email: string): string {
  const lowered = email.trim().toLowerCase();
  const at = lowered.lastIndexOf('@');
  if (at < 0) return lowered;
  let local = lowered.slice(0, at);
  let domain = lowered.slice(at + 1);
  const plus = local.indexOf('+');
  if (plus >= 0) local = local.slice(0, plus);
  if (domain === 'gmail.com' || domain === 'googlemail.com') {
    local = local.replace(/\./g, '');
    domain = 'gmail.com';
  }
  return `${local}@${domain}`;
}

/**
 * 原子认领某个规范化邮箱的 welcome bonus 名额。返回:
 *   true  = 本 subject 持有该规范化邮箱的名额(全新认领,或之前就是它占的,
 *           说明是同一用户重试)→ 本次可发放。
 *   false = 该规范化邮箱已被**别的** subject 占过(别名薅羊毛)→ 跳过发放。
 * 须传 service client(welcome_bonus_grants RLS 默认拒绝,靠 service_role 绕过)。
 *
 * 用 ignoreDuplicates 的 upsert 抢占;冲突时不返回行,需再 select 看 owner:
 * owner=自己 → 同用户重试(发额度那步之前失败过),允许继续;owner≠自己 → 已被占。
 */
async function claimWelcomeBonus(
  svcSupa: SupabaseClient,
  normalizedEmail: string,
  subjectId: string,
): Promise<boolean> {
  const { data, error } = await svcSupa
    .from('welcome_bonus_grants')
    .upsert(
      { normalized_email: normalizedEmail, subject_id: subjectId },
      { onConflict: 'normalized_email', ignoreDuplicates: true },
    )
    .select('subject_id');
  if (error) {
    // 认领失败(如表缺失/权限)——best-effort,宁可不发也别把请求搞挂。
    console.warn('[billing-grant.claimWelcomeBonus] failed', (error as { message?: string })?.message);
    return false;
  }
  // 抢占成功:返回了刚插入的行。
  if (Array.isArray(data) && data.length > 0) return true;
  // 冲突(已有人占):查 owner —— 是自己则视为本用户重试,允许继续发放。
  const { data: owner } = await svcSupa
    .from('welcome_bonus_grants')
    .select('subject_id')
    .eq('normalized_email', normalizedEmail)
    .maybeSingle();
  return (owner as { subject_id?: string } | null)?.subject_id === subjectId;
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
  if (!(await billingEnabled(env)) || !polarReady(env)) return;
  // 幂等键**格式不变**:线上已有 `signup:<auth user id>` 的历史行,改成 subject id
  // 会让老用户被重复发放。变的只是钱记在谁名下(subject_id)。
  const externalRef = `signup:${userId}`;
  // 入账主体 = 该用户的 user_account subject:pnc_ledger.subject_id 与
  // welcome_bonus_grants.subject_id 都有外键指向 subjects,写 auth user id 会直接
  // 违反外键;Polar customer 的 external_id 也是这个键。见 billing/subject-key.ts。
  let subjectId: string;
  try {
    subjectId = await resolveUserWalletSubjectId(svcSupa, userId);
  } catch (err) {
    console.error('[billing-grant.grantSignupBonus] wallet subject unresolved, skip', userId, err);
    return;
  }
  try {
    const { data: existing } = await svcSupa
      .from('pnc_ledger')
      .select('id')
      .eq('subject_id', subjectId)
      .eq('source', 'signup')
      .eq('external_ref', externalRef)
      .maybeSingle();
    if (existing) return; // 本 userId 已发过
    const email = await fetchEmail(svcSupa, userId);
    if (!email) return; // 没邮箱建不了 customer;下次再试
    // 防 +别名/点号薅羊毛(#252):按规范化邮箱去重。先原子认领该规范化邮箱的
    // 名额,被占(同一真实信箱已领过)则直接跳过发放。
    const claimed = await claimWelcomeBonus(svcSupa, normalizeEmail(email), subjectId);
    if (!claimed) return; // 该规范化邮箱的 welcome 名额已被占,跳过
    const micros = SIGNUP_BONUS_PNC * MICROS_PER_PNC;
    const om = polar(env);
    await om.ensureCustomer(subjectId, email);
    const r = await recordCreditIn(svcSupa, om, {
      subjectId,
      kind: 'admin',
      source: 'signup',
      externalRef,
      pncMicros: micros,
    });
    if (r.applied) await wallet.credit(env, subjectId, micros).catch(() => undefined);
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
  // 入账主体 = user_account subject(同 grantSignupBonus)。解析不到就抛 ——
  // 这是"钱进来"的路径,兑换码已被 billing_redeem 标记 used,静默吞掉等于吃掉用户
  // 的码;抛出去让调用方 500,用户可重试(recordCreditIn 按 code id 幂等)。
  const subjectId = await resolveUserWalletSubjectId(svcSupa, userId);
  const email = await fetchEmail(svcSupa, userId);
  const om = polar(env);
  if (email) await om.ensureCustomer(subjectId, email);
  await recordCreditIn(svcSupa, om, {
    subjectId,
    kind: 'redemption',
    source: 'redemption',
    externalRef: codeId,
    pncMicros: micros,
  });
  await wallet.credit(env, subjectId, micros).catch(() => undefined);
  return micros;
}
