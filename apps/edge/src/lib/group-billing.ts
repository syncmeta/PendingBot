import { serviceClient } from './supabase';
import { deleteCachedBalance } from './balance-cache';
import { estimateTokens } from '../llm/token-estimate';
import type { Env } from '../types';

// Group cost-split — single transactional debit across all participating
// members of a group. Called when an audit_log row is written for a
// group conversation; replaces the single-user billingDebit() that 1v1
// convs use.
//
// Algorithm:
//   1. Read group_billing_config + the active payer set (participates=
//      true && !overdrawn). Newcomers within new_member_grace_seconds
//      are forced into per_head regardless of mode (so they can't be
//      hit with 100% of a routing call before they've spoken).
//   2. Compute share_bps for each payer per mode.
//   3. Walk each share: skip 'skipped_overdrawn' if balance can't cover,
//      skip 'skipped_capped' if their per-group cap is exhausted; mark
//      'debited' otherwise. Skipped portions are NOT redistributed —
//      the missed credits are simply unbilled this turn (matches the
//      spec's "排除出本轮 split").
//   4. Call apply_audit_split RPC for atomic write.
//
// Skipped users get group_member_billing.overdrawn=true via the RPC's
// cap-trigger logic so the next call's balance scan excludes them up
// front.

export interface SplitInput {
  env: Env;
  /// audit_log row that just got written. Has conversation_id +
  /// cost_credits already on it; we re-read to be authoritative.
  auditLogId: string;
}

export async function splitAndDebit(input: SplitInput): Promise<void> {
  const { env, auditLogId } = input;
  const supa = serviceClient(env);

  const { data: audit, error: auditErr } = await supa
    .from('audit_log')
    .select('id, conversation_id, cost_credits, billing_status')
    .eq('id', auditLogId)
    .single();
  if (auditErr || !audit) {
    console.warn('[group-billing] audit row not found', auditLogId);
    return;
  }
  if (!audit.conversation_id || audit.billing_status !== 'pending') return;
  const totalCredits = Number(audit.cost_credits ?? 0);
  if (totalCredits <= 0) {
    // Mark the row 'free' explicitly so it doesn't sit forever in 'pending'.
    await supa.from('audit_log').update({ billing_status: 'free' }).eq('id', auditLogId);
    return;
  }

  const conversationId = audit.conversation_id as string;
  const now = Date.now();

  // 1. Read config + payers.
  const [{ data: cfg }, { data: members }] = await Promise.all([
    supa
      .from('group_billing_config')
      .select('mode, window_seconds, new_member_grace_seconds')
      .eq('conversation_id', conversationId)
      .maybeSingle(),
    supa
      .from('group_member_billing')
      .select('user_id, participates, cap_credits, spent_credits, overdrawn, joined_at')
      .eq('conversation_id', conversationId),
  ]);
  if (!cfg) {
    console.warn('[group-billing] no billing config', conversationId);
    return;
  }

  const allMembers = (members ?? []).filter((m) => m.participates && !m.overdrawn);
  if (allMembers.length === 0) {
    await supa.from('audit_log').update({ billing_status: 'unbilled' }).eq('id', auditLogId);
    return;
  }

  // Read user balances in one round-trip.
  const userIds = allMembers.map((m) => m.user_id as string);
  const { data: balances } = await supa
    .from('users')
    .select('id, balance_credits')
    .in('id', userIds);
  const balanceMap = new Map(
    (balances ?? []).map((u) => [u.id as string, Number(u.balance_credits) || 0]),
  );

  // 2. Compute share_bps. Decide grace-period vs full-mode payers.
  const graceMs = (cfg.new_member_grace_seconds as number) * 1000;
  const gracePayers: typeof allMembers = [];
  const fullPayers: typeof allMembers = [];
  for (const m of allMembers) {
    const joined = m.joined_at ? new Date(m.joined_at as string).getTime() : now;
    if (now - joined < graceMs) gracePayers.push(m);
    else fullPayers.push(m);
  }

  const fullPayerIds = fullPayers.map((m) => m.user_id as string);
  const fullShareBps = await computeShareBps(supa, conversationId, fullPayers, cfg.mode as Mode, cfg.window_seconds as number);

  // Grace payers always go per_head over (grace + full count). The full
  // payers' shares get scaled down to the remaining bps after grace
  // covers its head share. Net result: 1/(N) for grace each, and the
  // mode-driven distribution among full payers covers the rest.
  const totalPayerCount = gracePayers.length + fullPayers.length;
  const graceShareEach = gracePayers.length > 0
    ? Math.floor(10000 / totalPayerCount)
    : 0;
  const graceTotalBps = graceShareEach * gracePayers.length;
  const fullScaleBps = 10000 - graceTotalBps;

  // Combine into a single per-user map.
  const sharesBps = new Map<string, number>();
  for (const m of gracePayers) sharesBps.set(m.user_id as string, graceShareEach);
  for (const id of fullPayerIds) {
    const raw = fullShareBps.get(id) ?? 0;
    const scaled = Math.floor((raw * fullScaleBps) / 10000);
    sharesBps.set(id, scaled);
  }

  // Round-off: distribute the residual bps to the largest-share payer
  // so the row sums to exactly 10000.
  let summed = 0;
  for (const v of sharesBps.values()) summed += v;
  if (summed < 10000 && sharesBps.size > 0) {
    let largest: string | null = null;
    let largestVal = -1;
    for (const [k, v] of sharesBps) {
      if (v > largestVal) {
        largestVal = v;
        largest = k;
      }
    }
    if (largest) sharesBps.set(largest, sharesBps.get(largest)! + (10000 - summed));
  }

  // 3. Apply caps + balance.
  const splits: Array<{
    user_id: string;
    share_bps: number;
    debited_credits: number;
    debit_status: 'debited' | 'skipped_overdrawn' | 'skipped_capped';
  }> = [];

  for (const m of allMembers) {
    const uid = m.user_id as string;
    const bps = sharesBps.get(uid) ?? 0;
    if (bps <= 0) continue;
    const allocated = Math.ceil((totalCredits * bps) / 10000);

    const cap = m.cap_credits != null ? Number(m.cap_credits) : null;
    const spent = Number(m.spent_credits ?? 0);
    const balance = balanceMap.get(uid) ?? 0;

    if (cap != null && spent + allocated > cap) {
      splits.push({
        user_id: uid,
        share_bps: bps,
        debited_credits: 0,
        debit_status: 'skipped_capped',
      });
      continue;
    }
    if (balance < allocated) {
      splits.push({
        user_id: uid,
        share_bps: bps,
        debited_credits: 0,
        debit_status: 'skipped_overdrawn',
      });
      continue;
    }
    splits.push({
      user_id: uid,
      share_bps: bps,
      debited_credits: allocated,
      debit_status: 'debited',
    });
  }

  // 4. Single atomic write.
  const { error: rpcErr } = await supa.rpc('apply_audit_split', {
    p_audit_log_id: auditLogId,
    p_splits: splits as unknown as never,
  });
  if (rpcErr) {
    console.error('[group-billing] apply_audit_split failed', rpcErr.message);
    return;
  }

  // Flip billing_status on the audit row to reflect what actually
  // happened. If anyone was billed → 'billed'; otherwise 'unbilled'.
  const anyDebited = splits.some((s) => s.debit_status === 'debited');
  await supa
    .from('audit_log')
    .update({ billing_status: anyDebited ? 'billed' : 'unbilled' })
    .eq('id', auditLogId);

  // Invalidate the KV balance cache for every actually-billed member.
  // We don't know the post-debit balance without an extra round-trip
  // (apply_audit_split doesn't return per-user remaining balance), so
  // dropping the entry forces the next requireBalance to refresh from
  // Supabase. Cheaper than a per-user RPC + write here.
  await Promise.all(
    splits
      .filter((s) => s.debit_status === 'debited')
      .map((s) => deleteCachedBalance(env, s.user_id).catch(() => undefined)),
  );
}

// ─────────────────────────────────────────────────────────────────────
// share_bps computation per mode
// ─────────────────────────────────────────────────────────────────────

type Mode = 'custom' | 'per_head' | 'per_message' | 'per_token' | 'hybrid';
type MemberRow = { user_id: string };

async function computeShareBps(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  payers: MemberRow[],
  mode: Mode,
  windowSeconds: number,
): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  if (payers.length === 0) return out;

  if (mode === 'per_head') {
    return perHead(payers);
  }

  if (mode === 'custom') {
    const { data: shares } = await supa
      .from('group_billing_custom_shares')
      .select('user_id, weight_bps')
      .eq('conversation_id', conversationId);
    const lookup = new Map((shares ?? []).map((s) => [s.user_id as string, Number(s.weight_bps)]));
    let total = 0;
    for (const p of payers) total += lookup.get(p.user_id) ?? 0;
    if (total === 0) {
      // Fallback to per_head when custom shares aren't filled in. Surfaces
      // as an actually-billed split rather than 100% to a phantom user.
      return perHead(payers);
    }
    for (const p of payers) {
      const w = lookup.get(p.user_id) ?? 0;
      out.set(p.user_id, Math.floor((w * 10000) / total));
    }
    return out;
  }

  // per_message / per_token / hybrid all need a window scan of human
  // messages by sender.
  const since = new Date(Date.now() - windowSeconds * 1000).toISOString();
  const { data: msgs } = await supa
    .from('messages')
    .select('user_id, content, role')
    .eq('conversation_id', conversationId)
    .in('role', ['user', 'human'])
    .gt('created_at', since)
    .limit(5000);

  const counts = new Map<string, number>();
  const tokens = new Map<string, number>();
  for (const m of msgs ?? []) {
    const uid = m.user_id as string | null;
    if (!uid) continue;
    counts.set(uid, (counts.get(uid) ?? 0) + 1);
    tokens.set(uid, (tokens.get(uid) ?? 0) + estimateTokens(m.content as string | null));
  }

  if (mode === 'per_message') {
    return weightedSplit(payers, counts);
  }
  if (mode === 'per_token') {
    return weightedSplit(payers, tokens);
  }
  // hybrid: 50% per_message + 50% per_token. Compute each component and
  // average. Components may diverge wildly (e.g. one user posts a 5000-
  // token essay, another posts 50 one-liners) — averaging smooths that.
  const halfA = weightedSplit(payers, counts);
  const halfB = weightedSplit(payers, tokens);
  for (const p of payers) {
    const a = halfA.get(p.user_id) ?? 0;
    const b = halfB.get(p.user_id) ?? 0;
    out.set(p.user_id, Math.floor((a + b) / 2));
  }
  return out;
}

function perHead(payers: MemberRow[]): Map<string, number> {
  const out = new Map<string, number>();
  if (payers.length === 0) return out;
  const each = Math.floor(10000 / payers.length);
  for (const p of payers) out.set(p.user_id, each);
  return out;
}

function weightedSplit(payers: MemberRow[], weights: Map<string, number>): Map<string, number> {
  const out = new Map<string, number>();
  let total = 0;
  for (const p of payers) total += weights.get(p.user_id) ?? 0;
  if (total === 0) {
    // No human messages in window — fall back to per_head so the cost
    // of router calls / bot intros doesn't fall on whoever was first
    // to type historically.
    return perHead(payers);
  }
  for (const p of payers) {
    const w = weights.get(p.user_id) ?? 0;
    out.set(p.user_id, Math.floor((w * 10000) / total));
  }
  return out;
}
