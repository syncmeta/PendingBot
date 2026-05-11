import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runScroll, resolveEnvelopeSettings, HARD_CAP_TURNS } from '../lib/scroll-runner';
import { requireBalance, InsufficientBalanceError } from '../lib/billing';
import type { AppBindings } from '../types';
import type { Json } from '../db/schema';

// 奏折/Scroll routes — surfaced to users as 来信/Envelopes. The trigger
// body now carries the per-run config the user picked in conversation
// settings (explorer/collaborator models, search/scrape providers,
// turn cap). Caller-supplied settings win; otherwise we read whatever
// the conversation has saved; otherwise defaults.

export const scrollRoutes = new Hono<AppBindings>();
scrollRoutes.use('*', requireSession());

// All settings are optional — server fills in defaults via
// resolveEnvelopeSettings. Empty string for collaboratorModel means
// "no collaborator" (vs. unset which means "use default"). turnCap
// is clamped to [1, HARD_CAP_TURNS].
const SettingsBody = z
  .object({
    explorerModel: z.string().optional(),
    collaboratorModel: z.string().nullable().optional(),
    searchProvider: z.enum(['brave', 'tavily', 'exa', 'serper']).optional(),
    scrapeProvider: z.enum(['firecrawl', 'tavily', 'exa']).optional(),
    turnCap: z.number().int().min(1).max(HARD_CAP_TURNS).optional(),
    historyTokenBudgetPct: z.number().int().min(1).max(100).optional(),
  })
  .strict()
  .optional();

const TriggerBody = z.object({
  conversationId: z.string().uuid(),
  trigger: z.enum(['user', 'auto']).optional(),
  settings: SettingsBody,
});

// POST /v1/scroll/trigger
//   Kicks off a scroll run for the given user_bot conversation. The bot
//   reads its own history with the user, optionally surfs the web, and
//   writes an article. Returns 202 with the run id; the iOS client
//   subscribes to scroll_runs Realtime to watch progress.
scrollRoutes.post('/trigger', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof TriggerBody>;
  try {
    parsed = TriggerBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // RLS-gate: confirm the caller participates in this conv and that it
  // has a pinned bot we can run on its behalf. Also pull the saved
  // envelope_settings so we can fall through body → conv defaults →
  // hard defaults inside resolveEnvelopeSettings.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, bot_id, envelope_settings')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);
  if (!conv.bot_id) {
    return c.json({ error: 'conversation has no bot to write the scroll' }, 400);
  }

  // Caller-supplied settings win; fall through to whatever the
  // conversation saved last; resolveEnvelopeSettings fills the rest.
  const savedSettings =
    conv.envelope_settings && typeof conv.envelope_settings === 'object'
      ? (conv.envelope_settings as Record<string, unknown>)
      : null;
  const settings = resolveEnvelopeSettings({
    ...(savedSettings ?? {}),
    ...(parsed.settings ?? {}),
  });

  // If the caller passed settings, persist them as the conversation's
  // new defaults so the next manual trigger (and the auto-trigger when
  // it lands) follows the same config without resending the body.
  if (parsed.settings) {
    await supaUser
      .from('conversations')
      .update({ envelope_settings: settings as unknown as Json })
      .eq('id', parsed.conversationId);
  }

  // Billing gate. A scroll is multi-step LLM work (probably the most
  // expensive single trigger we have); reject up-front when balance is
  // below threshold rather than burn credits half-way through.
  try {
    await requireBalance(supaUser, userId);
  } catch (err) {
    if (err instanceof InsufficientBalanceError) {
      return c.json(
        {
          error: 'insufficient_balance',
          balance_credits: err.balance,
          min_threshold: err.threshold,
        },
        402,
      );
    }
    throw err;
  }

  const supa = serviceClient(c.env);
  const { data: run, error: runErr } = await supa
    .from('scroll_runs')
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
    return c.json({ error: 'database', detail: runErr?.message ?? 'insert failed' }, 500);
  }

  c.executionCtx.waitUntil(
    runScroll({
      env: c.env,
      scrollRunId: run.id as string,
      conversationId: parsed.conversationId,
      userId,
      botId: conv.bot_id as string,
      settings,
    }),
  );

  return c.json({ scrollRunId: run.id }, 202);
});

// GET /v1/scroll/list?limit&before
//   Paginated feed of this user's scrolls (newest first). Only completed
//   articles surface — running rows are picked up via Realtime, not list.
//   `before` is an ISO timestamp from the previous page's tail.
scrollRoutes.get('/list', async (c) => {
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
    .from('scroll_runs')
    .select('id, bot_id, conversation_id, status, title, summary, created_at, finished_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (before) q = q.lt('created_at', before);

  const { data, error } = await q;
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ items: data ?? [] });
});

// GET /v1/scroll/:id — full article (body_md included).
scrollRoutes.get('/:id', async (c) => {
  const id = c.req.param('id');
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('scroll_runs')
    .select('id, bot_id, conversation_id, status, title, summary, body_md, progress, settings, turns, created_at, started_at, finished_at')
    .eq('id', id)
    .maybeSingle();
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  if (!data) return c.json({ error: 'not found' }, 404);
  return c.json(data);
});

// POST /v1/scroll/letter
//   Human-authored letter to a mutual friend. Same scroll_runs row
//   shape as a bot envelope but kind='human', author_user_id set, no
//   bot_id, status='done' on insert (no async runner). The recipient
//   sees it on their 来信 tab via the existing scroll-feed Realtime
//   filter (user_id=eq.<recipient>). Mutual-friend gating happens
//   server-side too (RLS + this handler) — the iOS sheet only shows
//   the entry for user_user convs but RLS is the real backstop.
const LetterBody = z.object({
  conversationId: z.string().uuid(),
  recipientUserId: z.string().uuid(),
  title: z.string().trim().max(200).optional(),
  bodyMd: z.string().min(1).max(50_000),
});

scrollRoutes.post('/letter', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof LetterBody>;
  try {
    parsed = LetterBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  if (parsed.recipientUserId === userId) {
    return c.json({ error: 'cannot send a letter to yourself' }, 400);
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
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);
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
  if (mutualErr) return c.json({ error: 'database', detail: mutualErr.message }, 500);
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
    .from('scroll_runs')
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
    return c.json({ error: 'database', detail: insertErr?.message ?? 'insert failed' }, 500);
  }

  return c.json({ scrollRunId: row.id }, 201);
});

// POST /v1/scroll/:id/cancel — flip status='cancelled'. The runner
// checks this between turns and exits cleanly.
scrollRoutes.post('/:id/cancel', async (c) => {
  const id = c.req.param('id');
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { error } = await supa
    .from('scroll_runs')
    .update({ status: 'cancelled', finished_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ ok: true });
});
