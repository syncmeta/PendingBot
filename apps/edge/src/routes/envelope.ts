import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runEnvelope, resolveEnvelopeSettings, HARD_CAP_TURNS } from '../lib/envelope-runner';
import { gateConversation } from '../billing/usage-gate';
import { jsonError } from '../lib/http-error';
import { getModelRole } from '../lib/model-roles';
import type { AppBindings } from '../types';
import type { Json } from '../db/schema';

// Envelope (来信) routes. Mounted at /v1/envelope/* — see
// apps/edge/src/index.ts for the prefix.
//
// The trigger body may carry per-run config (explorer/collaborator
// models, turn cap). Caller-supplied settings win over the bot's own
// envelope defaults (bots.config.envelope); otherwise hard defaults.

export const envelopeRoutes = new Hono<AppBindings>();
envelopeRoutes.use('*', requireSession());

// All settings are optional — server fills in defaults via
// resolveEnvelopeSettings. Empty string for collaboratorModel means
// "no collaborator" (vs. unset which means "use default"). turnCap
// is clamped to [1, HARD_CAP_TURNS]. Legacy `searchProvider` /
// `scrapeProvider` keys on inbound bodies / saved rows are silently
// ignored (web tools now route through MCP → Exa).
const SettingsBody = z
  .object({
    explorerModel: z.string().optional(),
    collaboratorModel: z.string().nullable().optional(),
    turnCap: z.number().int().min(1).max(HARD_CAP_TURNS).optional(),
    historyTokenBudgetPct: z.number().int().min(1).max(100).optional(),
  })
  .optional();

const TriggerBody = z.object({
  conversationId: z.string().uuid(),
  trigger: z.enum(['user', 'auto']).optional(),
  settings: SettingsBody,
});

// POST /v1/envelope/trigger
//   Kicks off an envelope run for the given user_bot conversation. The bot
//   reads its own history with the user, optionally surfs the web, and
//   writes an article. Returns 202 with the run id; the iOS client
//   subscribes to envelope_runs Realtime to watch progress.
envelopeRoutes.post('/trigger', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof TriggerBody>;
  try {
    parsed = TriggerBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // RLS-gate: confirm the caller participates in this conv and that it
  // has a pinned bot we can run on its behalf.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, bot_id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return jsonError(c, 500, 'database_error', { detail: convErr.message });
  if (!conv) return jsonError(c, 404, 'conversation_no_access');
  if (!conv.bot_id) {
    return jsonError(c, 400, 'conversation_has_no_bot', { message: 'conversation has no bot to write the envelope' });
  }

  // Bot-level envelope defaults (bots.config.envelope) are the baseline
  // for every conversation with this bot.
  const { data: botRow } = await supaUser
    .from('bots')
    .select('config')
    .eq('id', conv.bot_id)
    .maybeSingle();
  const botEnvelopeDefaults =
    botRow?.config &&
    typeof botRow.config === 'object' &&
    !Array.isArray(botRow.config) &&
    typeof (botRow.config as Record<string, unknown>).envelope === 'object'
      ? ((botRow.config as Record<string, unknown>).envelope as Record<string, unknown>)
      : null;

  // Caller-supplied per-run settings win over the bot's defaults;
  // resolveEnvelopeSettings fills any remaining gaps with hard defaults.
  const settings = resolveEnvelopeSettings(
    {
      ...(botEnvelopeDefaults ?? {}),
      ...(parsed.settings ?? {}),
    },
    {
      explorerModel: await getModelRole(c.env, 'envelopeExplorer'),
      collaboratorModel: await getModelRole(c.env, 'envelopeCollaborator'),
    },
  );

  // Billing gate. An envelope is multi-step LLM work (probably the most
  // expensive single trigger we have); reject up-front when balance is
  // below threshold rather than burn credits half-way through.
  // 群感知门禁:群按池+认缴聚合,1v1 按发起人(计费 P2)。须用 service client
  // 读全群认缴。系统级级联不在此 gate。
  const supa = serviceClient(c.env);
  const gateErr = await gateConversation(c.env, supa, { userId, conversationId: parsed.conversationId });
  if (gateErr) {
    return c.json(
      {
        error: 'insufficient_balance',
        balance_credits: gateErr.balance,
        min_threshold: gateErr.threshold,
      },
      402,
    );
  }
  const { data: run, error: runErr } = await supa
    .from('envelope_runs')
    .insert({
      conversation_id: parsed.conversationId,
      user_id: userId,
      bot_id: conv.bot_id as string,
      status: 'running',
      trigger: parsed.trigger ?? 'user',
      progress: { phase: 'queued' },
      settings: settings as unknown as Json,
    })
    .select('id')
    .single();
  if (runErr || !run) {
    return jsonError(c, 500, 'database_error', { detail: runErr?.message ?? 'insert failed' });
  }

  c.executionCtx.waitUntil(
    runEnvelope({
      env: c.env,
      envelopeRunId: run.id as string,
      conversationId: parsed.conversationId,
      userId,
      botId: conv.bot_id as string,
      settings,
    }),
  );

  return c.json({ envelopeRunId: run.id }, 202);
});

// GET /v1/envelope/list?limit&before
//   Paginated feed of this user's envelopes (newest first). Only completed
//   articles surface — running rows are picked up via Realtime, not list.
//   `before` is an ISO timestamp from the previous page's tail.
envelopeRoutes.get('/list', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const limit = Math.min(50, Math.max(1, Number(c.req.query('limit') ?? 20)));
  const before = c.req.query('before');

  const supa = userClient(c.env, userJwt);
  // 来信 = received only. RLS opened SELECT to "recipient OR author" in 0065
  // so the sender can fetch their outgoing rows from other endpoints, but
  // the list endpoint must only return the inbox. Scope to user_id = caller:
  //   - bot envelopes have user_id = the requesting user (recipient = self)
  //   - human letters have user_id = recipient_user_id, author_user_id = sender
  //   So eq(user_id, caller) returns both bot envelopes and inbound human
  //   letters, and drops the caller's own outgoing rows.
  let q = supa
    .from('envelope_runs')
    .select('id, bot_id, conversation_id, status, title, summary, created_at, finished_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (before) q = q.lt('created_at', before);

  const { data, error } = await q;
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ items: data ?? [] });
});

// GET /v1/envelope/:id — full article (body_md included).
envelopeRoutes.get('/:id', async (c) => {
  const id = c.req.param('id');
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('envelope_runs')
    .select('id, bot_id, conversation_id, status, title, summary, body_md, progress, settings, turns, created_at, started_at, finished_at')
    .eq('id', id)
    .maybeSingle();
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  if (!data) return jsonError(c, 404, 'not_found');
  return c.json(data);
});

// POST /v1/envelope/letter
//   Human-authored letter to a mutual friend. Same envelope_runs row
//   shape as a bot envelope but kind='human', author_user_id set, no
//   bot_id, status='done' on insert (no async runner). The recipient
//   sees it on their 来信 tab via the existing envelope-feed Realtime
//   filter (user_id=eq.<recipient>). Mutual-friend gating happens
//   server-side too (RLS + this handler) — the iOS sheet only shows
//   the entry for user_user convs but RLS is the real backstop.
const LetterBody = z.object({
  conversationId: z.string().uuid(),
  recipientUserId: z.string().uuid(),
  title: z.string().trim().max(200).optional(),
  bodyMd: z.string().min(1).max(50_000),
});

envelopeRoutes.post('/letter', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof LetterBody>;
  try {
    parsed = LetterBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (parsed.recipientUserId === userId) {
    return jsonError(c, 400, 'self_chat_not_allowed', { message: 'cannot send a letter to yourself' });
  }

  const supaUser = userClient(c.env, userJwt);

  // Confirm caller participates in the conversation and that it's a
  // user_user conv with the named peer. RLS would catch a wrong
  // conversation_id, but the kind/peer pairing is a logic check on top.
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, conversation_type')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return jsonError(c, 500, 'database_error', { detail: convErr.message });
  if (!conv) return jsonError(c, 404, 'conversation_no_access');
  if (conv.conversation_type !== 'user_user') {
    return c.json(
      { error: 'letters can only be sent inside a user-to-user conversation' },
      400,
    );
  }

  // Mutual-friend gate. The RLS WITH CHECK calls are_mutual_friends
  // too; we check up-front so we can return a 403 with a clear reason
  // instead of the RLS rejection looking like a generic 500 / 42501.
  const { data: mutual, error: mutualErr } = await supaUser.rpc('are_mutual_friends', {
    a: userId,
    b: parsed.recipientUserId,
  });
  if (mutualErr) return jsonError(c, 500, 'database_error', { detail: mutualErr.message });
  if (!mutual) {
    return c.json(
      { error: 'not_mutual_friends', detail: '只能给互为好友的人写信' },
      403,
    );
  }

  // Title is optional — fall back to the first non-empty line of the
  // body, capped, so the feed row has something to show.
  const fallbackTitle = parsed.bodyMd
    .split('\n')
    .map((s) => s.trim().replace(/^#+\s*/, ''))
    .find((s) => s.length > 0)
    ?.slice(0, 80);
  const title = (parsed.title?.trim() || fallbackTitle || '来信').slice(0, 200);
  const summary = parsed.bodyMd.replace(/\s+/g, ' ').trim().slice(0, 200);

  const nowIso = new Date().toISOString();
  const { data: row, error: insertErr } = await supaUser
    .from('envelope_runs')
    .insert({
      conversation_id: parsed.conversationId,
      user_id: parsed.recipientUserId,
      author_user_id: userId,
      kind: 'human',
      status: 'done',
      trigger: 'user',
      progress: { phase: 'done' } as Json,
      turns: [] as unknown as Json,
      title,
      summary,
      body_md: parsed.bodyMd,
      started_at: nowIso,
      finished_at: nowIso,
    })
    .select('id')
    .single();
  if (insertErr || !row) {
    return jsonError(c, 500, 'database_error', { detail: insertErr?.message ?? 'insert failed' });
  }

  return c.json({ envelopeRunId: row.id }, 201);
});

// POST /v1/envelope/:id/cancel — flip status='cancelled'. The runner
// checks this between turns and exits cleanly.
envelopeRoutes.post('/:id/cancel', async (c) => {
  const id = c.req.param('id');
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { error } = await supa
    .from('envelope_runs')
    .update({ status: 'cancelled', finished_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ ok: true });
});
