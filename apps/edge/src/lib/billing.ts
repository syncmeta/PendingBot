import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import { billingEnabled } from './feature-flags';
import { wallet } from '../billing/wallet-client';
import { resolveUserWalletSubjectId } from '../billing/subject-key';

// Billing layer (P0). All schema changes ship in 0033_billing.sql /
// 0034_billing_admin_rpcs.sql. This module is the single point that knows
// about cost_credits, balance fields, and the billing_* RPCs.

// USD→PND markup conversion (getMarkup / usdToPnd / USD_TO_PND /
// DEFAULT_MARKUP + isolate cache) 已删:billing-v1 残留。运行时扣费走
// usdToPncMicros(billing/pnc.ts,pnc_micros、无 runtime markup),语音
// 成本预览(voice-metering.ts)是最后一个运行时消费者,已切到同口径;
// markup 只在 Polar 充值包售卖侧体现,不参与 live vendor cost 计价。

// ---------------------------------------------------------------------------
// Balance lookup
// ---------------------------------------------------------------------------

// getBalance(读 users.balance_credits / lifetime_* + /v1/me/balance 端点)已删:
// billing-v1 僵尸路径 —— users.balance_credits 在 WalletDO/Polar 切换后已无写入方,
// iOS 也不再调 /v1/me/balance。主体余额统一走 WalletDO(见 getBalanceGateState 下方
// + billing/wallet-client.ts:wallet.gate)。列本身的 DROP 留给后续迁移。

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
  // strong-consistent WalletDO cached balance and blocks only when
  // EXHAUSTED (≤ 0) — design §7 hard-stop. `balance_credits` carries PNC
  // micros (the field name is v1-legacy; callers branch on `allowed` +
  // surface the number). WalletDO is the cache, so no extra KV layer here.
  //
  // 钱包主体键 = 该用户的 user_account subject id(**不是** auth user id):
  // 充值/赠送只可能记在 subject 上(pnc_ledger 外键),用 user id 会落到另一个
  // 空 DO,变成"充多少都余额耗尽"。见 billing/subject-key.ts。
  let subjectId: string;
  try {
    subjectId = await resolveUserWalletSubjectId(supa, userId);
  } catch (err) {
    // 解析不到主体 = 我们不知道该读哪个钱包。明确 fail-open(放行)并 **报错级**
    // 日志:静默当成 0 余额正是 2026-08-18 事故的形态,绝不再犯。
    console.error('[billing.getBalanceGateState] wallet subject unresolved, fail-open', userId, err);
    return { balance_credits: 0, min_threshold: 0, allowed: true };
  }
  let micros: number;
  try {
    ({ balanceMicros: micros } = await wallet.gate(env, subjectId));
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
  if (!(await billingEnabled(env))) return;
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
