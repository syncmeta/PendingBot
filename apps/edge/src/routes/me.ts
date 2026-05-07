import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { getUserMemory } from '../lib/memory';
import { userClient } from '../lib/supabase';
import {
  getBalance,
  getConfigInt,
  redeemCode,
  RedemptionError,
} from '../lib/billing';
import type { AppBindings } from '../types';

export const meRoutes = new Hono<AppBindings>();
meRoutes.use('*', requireSession());

// GET /v1/me/memory — transparency UI: "what bots see in me".
// Backed by KV (Honcho user-peer representation, refreshed after each turn).
// Per plan/02 this is the ONLY surface that exposes user representation —
// it's never injected into any bot's system prompt.
meRoutes.get('/memory', async (c) => {
  const userId = c.var.userId!;
  const memory = await getUserMemory(c.env, userId);
  if (!memory) {
    return c.json({ card: [], representation: '', syncedAt: null });
  }
  return c.json(memory);
});

// GET /v1/me/balance — current credit balance + lifetime totals + the
// configured min-threshold so the client can show the "needs topup" hint
// without a second round-trip.
meRoutes.get('/balance', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const [balance, threshold] = await Promise.all([
    getBalance(supa, userId),
    getConfigInt(supa, 'min_balance_threshold'),
  ]);
  return c.json({
    balance_credits: balance?.balance_credits ?? 0,
    lifetime_topup_credits: balance?.lifetime_topup_credits ?? 0,
    lifetime_spent_credits: balance?.lifetime_spent_credits ?? 0,
    min_threshold: threshold ?? 0,
  });
});

// POST /v1/me/redeem — trade a redemption code for credits. Atomic in
// the DB (billing_redeem RPC, FOR UPDATE + same-tx ledger insert);
// here we only translate error codes back to HTTP.
meRoutes.post('/redeem', async (c) => {
  const userJwt = c.var.userJwt!;
  let body: { code?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: 'invalid_body' }, 400);
  }
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!code) {
    return c.json({ error: 'missing_code' }, 400);
  }

  // billing_redeem reads auth.uid() — must use user-scoped client.
  const supa = userClient(c.env, userJwt);
  try {
    const result = await redeemCode(supa, code);
    return c.json({
      ok: true,
      credits: result.credits,
      new_balance: result.new_balance,
    });
  } catch (err) {
    if (err instanceof RedemptionError) {
      const status = err.kind === 'not_authenticated' ? 401 : 400;
      return c.json({ error: err.kind, message: err.message }, status);
    }
    console.error('[me/redeem] unexpected', err);
    return c.json({ error: 'internal' }, 500);
  }
});

// GET /v1/me/billing/history — recent billable activity. Combines two
// sources:
//   - audit_log rows (LLM consumes) where billing_status in ('billed','unbilled')
//   - billing_ledger rows (topups, grants, redemptions, refunds, adjusts)
// Both are filtered to the calling user via RLS (audit_log_self_read +
// billing_ledger_self_read policies in 0033). We merge and sort
// client-side here for v1; if volume grows we'll move to a DB view.
meRoutes.get('/billing/history', async (c) => {
  const userJwt = c.var.userJwt!;
  const limitParam = parseInt(c.req.query('limit') ?? '50', 10);
  const limit = Number.isFinite(limitParam)
    ? Math.min(Math.max(limitParam, 1), 200)
    : 50;
  const supa = userClient(c.env, userJwt);

  // The new fields aren't typed yet — same untyped escape hatch as
  // billing.ts. After schema.ts regen these can be plain typed selects.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const supaAny = supa as any;

  const [auditRes, ledgerRes] = await Promise.all([
    supaAny
      .from('audit_log')
      .select(
        'id, created_at, task_type, model_id, cost_credits, billing_status, conversation_id',
      )
      .in('billing_status', ['billed', 'unbilled'])
      .order('created_at', { ascending: false })
      .limit(limit),
    supaAny
      .from('billing_ledger')
      .select('id, created_at, entry_type, delta_credits, reason')
      .order('created_at', { ascending: false })
      .limit(limit),
  ]);

  const consumes = (auditRes.data ?? []).map(
    (r: {
      id: string;
      created_at: string;
      task_type: string;
      model_id: string;
      cost_credits: number;
      billing_status: string;
      conversation_id: string | null;
    }) => ({
      kind: 'consume' as const,
      id: r.id,
      created_at: r.created_at,
      delta_credits: -Number(r.cost_credits),
      task_type: r.task_type,
      model_id: r.model_id,
      conversation_id: r.conversation_id,
      billing_status: r.billing_status,
    }),
  );
  const movements = (ledgerRes.data ?? []).map(
    (r: {
      id: string;
      created_at: string;
      entry_type: string;
      delta_credits: number;
      reason: string | null;
    }) => ({
      kind: 'movement' as const,
      id: r.id,
      created_at: r.created_at,
      delta_credits: Number(r.delta_credits),
      entry_type: r.entry_type,
      reason: r.reason,
    }),
  );
  const merged = [...consumes, ...movements].sort((a, b) =>
    a.created_at < b.created_at ? 1 : -1,
  );
  return c.json({ items: merged.slice(0, limit) });
});
