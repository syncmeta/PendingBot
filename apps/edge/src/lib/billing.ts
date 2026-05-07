import type { SupabaseClient } from './supabase';

// Billing layer (P0). All schema changes ship in 0033_billing.sql /
// 0034_billing_admin_rpcs.sql. This module is the single point that knows
// about cost_credits, balance fields, and the billing_* RPCs.

// 1 USD ≈ 1000 credits internal accounting unit. Credits ↔ display dollars
// is a per-channel ratio (Apple IAP / Stripe / redemption may differ); 1000
// just makes ceil() arithmetic land on whole credits for typical per-call
// LLM costs (a $0.0002 call → 1 credit at 2.5× markup).
const USD_TO_CREDITS = 1000;

// Markup over our wholesale provider cost. WorldRouter is ~70% of OpenRouter
// list; Apple IAP takes 30%; we still want margin for ops + free tier
// signup grant. 2.5× is the conservative starting point; tune in P1 once
// real consumption shows up.
const MARKUP = 2.5;

// Pre-call gate threshold default — read from billing_config at runtime.
// 0 means "no gate" (don't block anyone); deny only when the value is
// configured AND the user falls below it.
const DEFAULT_MIN_THRESHOLD = 0;

/**
 * Convert a USD cost to integer credits, applying markup.
 *
 * Returns 0 for null / 0 / negative inputs (e.g. fallback flows where the
 * provider responded but we don't have alias pricing — we don't know the
 * cost so we don't bill).
 */
export function usdToCredits(costUsd: number | null | undefined): number {
  if (!costUsd || costUsd <= 0) return 0;
  return Math.ceil(costUsd * USD_TO_CREDITS * MARKUP);
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

/**
 * Throw InsufficientBalanceError when balance < min_balance_threshold.
 * Call this BEFORE issuing an LLM request from a user-initiated path
 * (message reply, scroll, review). Skip for system-triggered cascades
 * (title, lookback, bot_note) — those bill but don't gate.
 */
export async function requireBalance(
  supa: SupabaseClient,
  userId: string,
): Promise<void> {
  const [bal, threshold] = await Promise.all([
    getBalance(supa, userId),
    getConfigInt(supa, 'min_balance_threshold'),
  ]);
  const balance = bal?.balance_credits ?? 0;
  const t = threshold ?? DEFAULT_MIN_THRESHOLD;
  if (t > 0 && balance < t) {
    throw new InsufficientBalanceError(balance, t);
  }
}

// ---------------------------------------------------------------------------
// Debit (Worker → DB after each LLM call)
// ---------------------------------------------------------------------------

/**
 * Apply the post-call debit to the user's balance and update
 * audit_log.billing_status. Always succeeds — even if balance goes
 * negative the row is marked 'unbilled' for ops to chase, and the next
 * pre-call gate blocks further requests.
 *
 * Pass the service-role supa client; the RPC is SECURITY DEFINER but
 * authenticated GRANT is intentionally not given (server-side only).
 *
 * Returns the new balance, or null on failure (logged + swallowed —
 * never propagate billing errors to the user-visible LLM response).
 */
export async function billingDebit(
  supa: SupabaseClient,
  userId: string,
  auditLogId: string,
  credits: number,
): Promise<number | null> {
  const { data, error } = await supa.rpc('billing_debit', {
    p_user_id: userId,
    p_audit_log_id: auditLogId,
    p_credits: credits,
  });
  if (error) {
    console.warn('[billing_debit]', error.message ?? String(error));
    return null;
  }
  return typeof data === 'number' ? data : null;
}

// ---------------------------------------------------------------------------
// Redeem (user-scoped RPC — auth.uid() inside)
// ---------------------------------------------------------------------------

export interface RedeemResult {
  credits: number;
  new_balance: number;
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
