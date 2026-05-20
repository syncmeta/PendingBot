import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { getUserMemory } from '../lib/memory';
import { userClient } from '../lib/supabase';
import {
  getBalance,
  getConfigInt,
  redeemCode,
  RedemptionError,
} from '../lib/billing';
import { putCachedBalance } from '../lib/balance-cache';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const meRoutes = new Hono<AppBindings>();
meRoutes.use('*', requireSession());

// GET /v1/me/profile — read-side for app-wide user preferences. Today
// only exposes notification_preview_mode (lock-screen privacy knob); add
// other preference fields here as they appear rather than scattering them
// across the API. Backed by users.custom_fields so no schema migration is
// needed per knob — the iOS side is the source of truth for available
// modes (the union here just enforces server-side normalisation).
meRoutes.get('/profile', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('users')
    .select('custom_fields')
    .eq('id', userId)
    .maybeSingle();
  if (error) {
    console.error('[me/profile] read failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  const cf = (data?.custom_fields ?? null) as Record<string, unknown> | null;
  const rawMode = cf?.notification_preview_mode;
  const mode =
    rawMode === 'name' || rawMode === 'name_content' ? rawMode : 'generic';
  return c.json({ notification_preview_mode: mode });
});

// PATCH /v1/me/profile — write-side. Merges into users.custom_fields so
// other keys the iOS side may have stashed (avatar_seed etc.) survive.
// RLS policy users_self_update gates this to the caller's own row.
const PatchProfileBody = z.object({
  notification_preview_mode: z.enum(['generic', 'name', 'name_content']).optional(),
});
meRoutes.patch('/profile', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  let body: z.infer<typeof PatchProfileBody>;
  try {
    body = PatchProfileBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  if (body.notification_preview_mode === undefined) {
    return c.json({ ok: true }); // nothing to patch
  }
  const supa = userClient(c.env, userJwt);
  const { data: existing } = await supa
    .from('users')
    .select('custom_fields')
    .eq('id', userId)
    .maybeSingle();
  const cf = ((existing?.custom_fields ?? {}) as Record<string, unknown>);
  cf.notification_preview_mode = body.notification_preview_mode;
  const { error } = await supa
    .from('users')
    .update({ custom_fields: cf as never })
    .eq('id', userId);
  if (error) {
    console.error('[me/profile] update failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  return c.json({ ok: true, notification_preview_mode: body.notification_preview_mode });
});

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
    return jsonError(c, 400, 'invalid_body');
  }
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!code) {
    return jsonError(c, 400, 'invalid_body', { message: 'missing code' });
  }

  // billing_redeem reads auth.uid() — must use user-scoped client.
  const supa = userClient(c.env, userJwt);
  const userId = c.var.userId!;
  try {
    const result = await redeemCode(supa, code);
    // Sync KV with the post-redemption balance so the next pre-call
    // gate sees the new value without a Supabase round-trip.
    await putCachedBalance(c.env, userId, result.new_balance).catch(() => undefined);
    return c.json({
      ok: true,
      credits: result.credits,
      new_balance: result.new_balance,
    });
  } catch (err) {
    if (err instanceof RedemptionError) {
      if (err.kind === 'not_authenticated') {
        return jsonError(c, 401, 'unauthorized', { message: err.message });
      }
      if (err.kind === 'not_found') {
        return jsonError(c, 400, 'redemption_not_found', { message: err.message });
      }
      if (err.kind === 'already_used') {
        return jsonError(c, 400, 'redemption_already_used', { message: err.message });
      }
      return jsonError(c, 400, 'internal_error', { message: err.message });
    }
    console.error('[me/redeem] unexpected', err);
    return jsonError(c, 500, 'internal_error');
  }
});

// GET /v1/me/billing/log?limit=50&before=<iso> — recent per-call
// charges for the iOS wallet's consumption list. Cursor pagination by
// `created_at` (descending). RLS scopes audit_log to the calling user
// (audit_log_self_read in 0033).
meRoutes.get('/billing/log', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);

  const limitParam = Number.parseInt(c.req.query('limit') ?? '', 10);
  const limit = Math.min(Math.max(Number.isFinite(limitParam) ? limitParam : 50, 1), 100);
  const before = c.req.query('before');

  let q = supa
    .from('audit_log')
    .select('id, created_at, task_type, model_id, cost_credits, billing_status, metadata')
    .in('billing_status', ['billed', 'unbilled'])
    .order('created_at', { ascending: false })
    .limit(limit);
  if (before) q = q.lt('created_at', before);

  const { data: rows, error } = await q;
  if (error) {
    console.error('[me/billing/log] query failed', error);
    return jsonError(c, 500, 'internal_error');
  }

  const turns = rows ?? [];

  const botIds = [
    ...new Set(
      turns
        .map((r) =>
          r.metadata && typeof r.metadata === 'object'
            ? ((r.metadata as Record<string, unknown>).bot_id as unknown)
            : null,
        )
        .filter((v): v is string => typeof v === 'string'),
    ),
  ];
  const { data: bots } = botIds.length
    ? await supa.from('bots').select('id, display_name').in('id', botIds)
    : { data: [] as { id: string; display_name: string }[] };
  const botName = new Map((bots ?? []).map((b) => [b.id, b.display_name]));

  const items = turns.map((r) => {
    const botId =
      r.metadata && typeof r.metadata === 'object'
        ? ((r.metadata as Record<string, unknown>).bot_id as unknown)
        : null;
    return {
      id: r.id,
      created_at: r.created_at,
      task_type: r.task_type,
      model_id: r.model_id,
      cost_credits: Number(r.cost_credits) || 0,
      billing_status: r.billing_status,
      bot_id: typeof botId === 'string' ? botId : null,
      bot_name: typeof botId === 'string' ? botName.get(botId) ?? null : null,
    };
  });

  const nextCursor =
    items.length === limit ? items[items.length - 1].created_at : null;

  return c.json({ items, next_cursor: nextCursor });
});

// GET /v1/me/billing/summary?range=7d|30d|90d — aggregated spend for
// the iOS wallet's audit charts (the wallet no longer shows a per-call
// list; the detailed log lives in the board's /audit page). Breaks the
// caller's billed/unbilled spend (cost_credits — LLM + folded tool
// spend) down by day, model, task type and bot. RLS scopes audit_log
// to the calling user (audit_log_self_read in 0033); volume per user is
// small enough to aggregate in the worker rather than in SQL.
meRoutes.get('/billing/summary', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const rangeParam = c.req.query('range') ?? '30d';
  const days = rangeParam === '7d' ? 7 : rangeParam === '90d' ? 90 : 30;
  const since = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();

  const { data: rows } = await supa
    .from('audit_log')
    .select('created_at, task_type, model_id, cost_credits, metadata')
    .in('billing_status', ['billed', 'unbilled'])
    .gte('created_at', since)
    .limit(5000);

  let total = 0;
  const byDay = new Map<string, number>();
  const byModel = new Map<string, number>();
  const byTask = new Map<string, number>();
  const byBot = new Map<string, number>();
  for (const r of rows ?? []) {
    const credits = Number(r.cost_credits) || 0;
    total += credits;
    byDay.set(r.created_at.slice(0, 10), (byDay.get(r.created_at.slice(0, 10)) ?? 0) + credits);
    const model = r.model_id || '(未知)';
    byModel.set(model, (byModel.get(model) ?? 0) + credits);
    byTask.set(r.task_type, (byTask.get(r.task_type) ?? 0) + credits);
    const botId =
      r.metadata && typeof r.metadata === 'object'
        ? (r.metadata as Record<string, unknown>).bot_id
        : null;
    if (typeof botId === 'string') {
      byBot.set(botId, (byBot.get(botId) ?? 0) + credits);
    }
  }

  // Resolve bot display names so the chart shows names, not uuids.
  const botIds = [...byBot.keys()];
  const { data: bots } = botIds.length
    ? await supa.from('bots').select('id, display_name').in('id', botIds)
    : { data: [] as { id: string; display_name: string }[] };
  const botName = new Map((bots ?? []).map((b) => [b.id, b.display_name]));

  const ranked = (m: Map<string, number>) =>
    [...m.entries()]
      .map(([key, credits]) => ({ key, credits }))
      .sort((a, b) => b.credits - a.credits);

  return c.json({
    range_days: days,
    total_credits: total,
    by_day: [...byDay.entries()]
      .map(([day, credits]) => ({ day, credits }))
      .sort((a, b) => (a.day < b.day ? -1 : 1)),
    by_model: ranked(byModel),
    by_task: ranked(byTask),
    by_bot: ranked(byBot).map((e) => ({
      key: e.key,
      label: botName.get(e.key) ?? e.key.slice(0, 8),
      credits: e.credits,
    })),
  });
});
