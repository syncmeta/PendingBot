import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import { billingEnabled } from './feature-flags';
import { wallet } from '../billing/wallet-client';

// Billing layer (P0). All schema changes ship in 0033_billing.sql /
// 0034_billing_admin_rpcs.sql. This module is the single point that knows
// about cost_credits, balance fields, and the billing_* RPCs.

// $1 USD list price = 2700 PND (Pending Name Credit, symbol ∂). This is
// the user-facing display ratio — IAP / Stripe / redemption all sell at
// the same headline rate. 2700 (vs a round 1000) gives larger nominal
// numbers in-app (signup bonus, per-call drain) without changing real
// markup; granularity also lands closer to per-token costs on cheap
// models so ceil() rounding bites less.
const USD_TO_PND = 2700;

// Default markup if billing_config.markup is missing. WorldRouter is ~70%
// of OpenRouter list; Apple IAP takes 30%; we want margin for ops + free
// tier signup grant. 2.5× was the seed value and stays as the fallback
// so a wiped billing_config never silently zeroes out billing.
const DEFAULT_MARKUP = 2.5;

// Worker-isolate cache for the markup value. The billing_config table is
// edited from the board roughly never; a short TTL keeps drift bounded
// without putting an extra DB roundtrip on every LLM turn. Match the
// web-tool price cache so admins see a consistent "≤ 60s after save"
// propagation window across the billing knobs.
const MARKUP_TTL_MS = 60_000;
let markupCache: { at: number; value: number } | null = null;

/**
 * Read billing_config.markup (numeric jsonb scalar). Falls back to
 * DEFAULT_MARKUP on missing key / bad value / DB error so a transient
 * Supabase issue can't break billing. Cached for MARKUP_TTL_MS.
 */
export async function getMarkup(supa: SupabaseClient): Promise<number> {
  const now = Date.now();
  if (markupCache && now - markupCache.at < MARKUP_TTL_MS) return markupCache.value;
  // getConfigInt reads a jsonb number — works for the markup float
  // too; the name is just historical (min_balance_threshold was the
  // only key for a while).
  const v = await getConfigInt(supa, 'markup');
  const value = v != null && v > 0 ? v : DEFAULT_MARKUP;
  markupCache = { at: now, value };
  return value;
}

/** For tests / forced refresh after an admin edit on the same isolate. */
export function _resetMarkupCache(): void {
  markupCache = null;
}

/**
 * Convert a USD provider cost to integer PND debit, applying markup.
 *
 * Callers fetch the markup once per call via getMarkup(supa) and pass
 * it here, rather than this function hitting the DB itself — keeps
 * usdToPnd pure/synchronous and makes the "what markup applied to
 * this debit" trail explicit at the call site.
 *
 * Returns 0 for null / 0 / negative inputs (e.g. fallback flows where the
 * provider responded but we don't have alias pricing — we don't know the
 * cost so we don't bill).
 *
 * Note: DB columns and SQL RPCs still use the legacy `_credits` suffix
 * (balance_credits, cost_credits, p_credits, …). They store PND values;
 * the column name is just historical and invisible to users.
 */
export function usdToPnd(
  costUsd: number | null | undefined,
  markup: number,
): number {
  if (!costUsd || costUsd <= 0) return 0;
  if (!Number.isFinite(markup) || markup <= 0) return 0;
  return Math.ceil(costUsd * USD_TO_PND * markup);
}

// ---------------------------------------------------------------------------
// Balance lookup
// ---------------------------------------------------------------------------

export interface BalanceInfo {
  balance_credits: number;
  lifetime_topup_credits: number;
  lifetime_spent_credits: number;
}

/**
 * Read the user's current balance + lifetime totals. Uses whichever
 * client is passed (user-scoped JWT for RLS-checked reads from /me, or
 * service-role for internal pre-call gating). Returns null if the user
 * row isn't visible / doesn't exist.
 */
export async function getBalance(
  supa: SupabaseClient,
  userId: string,
): Promise<BalanceInfo | null> {
  const { data, error } = await supa
    .from('users')
    .select('balance_credits, lifetime_topup_credits, lifetime_spent_credits')
    .eq('id', userId)
    .maybeSingle();
  if (error || !data) return null;
  return {
    balance_credits: Number(data.balance_credits) || 0,
    lifetime_topup_credits: Number(data.lifetime_topup_credits) || 0,
    lifetime_spent_credits: Number(data.lifetime_spent_credits) || 0,
  };
}

// getSubjectBalance(读 subject_wallets)已删(#226):subject_wallets 表退役,
// 主体余额统一走 WalletDO(Polar 缓存,见 billing/wallet-client.ts:wallet.gate)。
// /me/subject 已改为直接读 WalletDO。

/**
 * Read an integer scalar from billing_config. Returns null when the key
 * is missing or the value isn't a JSON number. Authenticated SELECT is
 * permitted by RLS so either client works.
 */
export async function getConfigInt(
  supa: SupabaseClient,
  key: string,
): Promise<number | null> {
  const { data, error } = await supa
    .from('billing_config')
    .select('value')
    .eq('key', key)
    .maybeSingle();
  if (error || !data) return null;
  const v = data.value;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

// ---------------------------------------------------------------------------
// Pre-call gate
// ---------------------------------------------------------------------------

export class InsufficientBalanceError extends Error {
  balance: number;
  threshold: number;
  constructor(balance: number, threshold: number) {
    super(`balance ${balance} below threshold ${threshold}`);
    this.name = 'InsufficientBalanceError';
    this.balance = balance;
    this.threshold = threshold;
  }
}

export interface BalanceGateState {
  balance_credits: number;
  min_threshold: number;
  allowed: boolean;
}

export async function getBalanceGateState(
  env: Env,
  supa: SupabaseClient,
  userId: string,
  _opts?: { readBalanceWhenDisabled?: boolean },
): Promise<BalanceGateState> {
  // WalletDO authoritative (计费 P2). The pre-call gate reads the user's
  // strong-consistent WalletDO cached balance (one DO per subject; here
  // subject = the user's own id for the 1v1/bot path — group convs skip
  // this gate entirely) and blocks only when EXHAUSTED (≤ 0) — design §7
  // hard-stop. `balance_credits` carries PNC micros (the field name is
  // v1-legacy; callers branch on `allowed` + surface the number).
  // WalletDO is the cache, so no extra KV layer here.
  void supa;
  let micros: number;
  try {
    ({ balanceMicros: micros } = await wallet.gate(env, userId));
  } catch (err) {
    // A WalletDO read failure must NOT hard-stop a paying user. Fail open
    // (allow) — the post-call debit + DO overdraft floor still bound spend.
    console.warn('[billing.getBalanceGateState] wallet.gate failed, fail-open', err);
    return { balance_credits: 0, min_threshold: 0, allowed: true };
  }
  return {
    balance_credits: micros,
    min_threshold: 0,
    allowed: micros > 0,
  };
}

/**
 * Throw InsufficientBalanceError when balance < min_balance_threshold.
 * Call this BEFORE issuing an LLM request from a user-initiated path
 * (message reply, envelope). Skip for system-triggered cascades
 * (title, lookback, bot_note) — those bill but don't gate.
 *
 * Reads:
 *   - threshold from the isolate-local cache (60s TTL, refreshes via
 *     Supabase on miss)
 *   - balance from the per-user KV cache; falls back to Supabase on
 *     miss and warms KV with the result. Subsequent debits keep the
 *     cache fresh via the billingDebit hook in router.ts.
 */
export async function requireBalance(
  env: Env,
  supa: SupabaseClient,
  userId: string,
): Promise<void> {
  // Kill-switch: billing off (default) → never block.
  if (!billingEnabled(env)) return;
  const gate = await getBalanceGateState(env, supa, userId);
  if (!gate.allowed) {
    throw new InsufficientBalanceError(gate.balance_credits, gate.min_threshold);
  }
}

// 旧的 billingDebit / billingDebitSubject(写 billing_debit / billing_debit_subject
// 旧钱包 RPC)已删:计费 P2 后扣费走 WalletDO(wallet.debit),这两个函数无任何调用方。
// 对应 RPC 在孤儿 drop 迁移里一并删除。

// ---------------------------------------------------------------------------
// Redeem (user-scoped RPC — auth.uid() inside)
// ---------------------------------------------------------------------------

export interface RedeemResult {
  /** PND 原值(v1 单位);edge 换 PNC micros 后入 Polar。 */
  credits: number;
  /** redemption_codes.id,作 Polar 入账幂等键(external_ref)。 */
  code_id: string;
}

export class RedemptionError extends Error {
  kind: 'not_authenticated' | 'not_found' | 'already_used' | 'unknown';
  constructor(kind: RedemptionError['kind'], message: string) {
    super(message);
    this.name = 'RedemptionError';
    this.kind = kind;
  }
}

/**
 * Redeem a code as the calling user. The supabase client MUST be a
 * userClient (anon key + user JWT) — billing_redeem reads auth.uid()
 * inside.
 */
export async function redeemCode(
  supa: SupabaseClient,
  code: string,
): Promise<RedeemResult> {
  const { data, error } = await supa.rpc('billing_redeem', { p_code: code });
  if (error) {
    const c = error.code;
    if (c === '42501') throw new RedemptionError('not_authenticated', error.message);
    if (c === 'P0002') throw new RedemptionError('not_found', error.message);
    if (c === 'P0001') throw new RedemptionError('already_used', error.message);
    throw new RedemptionError('unknown', error.message ?? String(error));
  }
  return data as unknown as RedeemResult;
}
