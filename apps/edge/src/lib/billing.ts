import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import { getCachedBalance, putCachedBalance } from './balance-cache';
import { kvConfig } from './kv-config';

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

// Pre-call gate threshold default — read from billing_config at runtime.
// 0 means "no gate" (don't block anyone); deny only when the value is
// configured AND the user falls below it.
const DEFAULT_MIN_THRESHOLD = 0;

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

// Same isolate-local pattern for the pre-call gate threshold. The value
// is global (one knob in billing_config), tiny, and changes rarely;
// caching it on the worker isolate avoids a KV round-trip in
// requireBalance and survives across requests within a single isolate.
const THRESHOLD_TTL_MS = 60_000;
const THRESHOLD_TTL_S = THRESHOLD_TTL_MS / 1000;
let thresholdCache: { at: number; value: number } | null = null;

// getThreshold sits on the message-send critical path (requireBalance).
// The KV read-through (shared L2 in front of the isolate Map) keeps a
// cold isolate off the cross-region Supabase round-trip.
export async function getThreshold(supa: SupabaseClient, env: Env): Promise<number> {
  const now = Date.now();
  if (thresholdCache && now - thresholdCache.at < THRESHOLD_TTL_MS) return thresholdCache.value;
  const value = await kvConfig(
    env,
    'cfg:billing:min_balance_threshold',
    THRESHOLD_TTL_S,
    async () => (await getConfigInt(supa, 'min_balance_threshold')) ?? DEFAULT_MIN_THRESHOLD,
  );
  thresholdCache = { at: now, value };
  return value;
}

export function _resetThresholdCache(): void {
  thresholdCache = null;
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

export type SubjectBalanceInfo = BalanceInfo;

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
 * Read a responsibility subject's wallet balance + lifetime totals.
 *
 * This is the subject-account mirror of getBalance. It intentionally
 * does not infer the subject from a user: callers must pass the already
 * resolved billing subject so temporary groups, group accounts, and
 * future Crew sessions cannot silently fall back to the wrong owner.
 */
export async function getSubjectBalance(
  supa: SupabaseClient,
  subjectId: string,
): Promise<SubjectBalanceInfo | null> {
  const { data, error } = await supa
    .from('subject_wallets')
    .select('balance_credits, lifetime_topup_credits, lifetime_spent_credits')
    .eq('subject_id', subjectId)
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
  const [cached, threshold] = await Promise.all([
    getCachedBalance(env, userId),
    getThreshold(supa, env),
  ]);
  if (threshold <= 0) return; // gate disabled globally — short-circuit

  if (cached) {
    if (cached.balance_credits < threshold) {
      throw new InsufficientBalanceError(cached.balance_credits, threshold);
    }
    return;
  }

  // Cache miss → Supabase. Warm KV with the result so the next call
  // skips the round-trip.
  const bal = await getBalance(supa, userId);
  const balance = bal?.balance_credits ?? 0;
  if (balance < threshold) {
    throw new InsufficientBalanceError(balance, threshold);
  }
  // Fire-and-forget warm. Errors are non-fatal — next miss re-reads.
  putCachedBalance(env, userId, balance).catch(() => undefined);
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

/**
 * Apply the post-call debit to a responsibility subject wallet.
 *
 * Temporary groups and Crew sessions should call this after resolving
 * their immutable billing subject. Existing user-wallet billing stays on
 * billingDebit until each old call path is deliberately migrated.
 */
export async function billingDebitSubject(
  supa: SupabaseClient,
  subjectId: string,
  auditLogId: string,
  credits: number,
): Promise<number | null> {
  const { data, error } = await supa.rpc('billing_debit_subject', {
    p_subject_id: subjectId,
    p_audit_log_id: auditLogId,
    p_credits: credits,
  });
  if (error) {
    console.warn('[billing_debit_subject]', error.message ?? String(error));
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
