import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runScroll } from '../lib/scroll-runner';
import type { AppBindings } from '../types';

// 奏折/Scroll routes — feed-style article output, manual trigger only
// (cron auto-trigger pending the user's testing).

export const scrollRoutes = new Hono<AppBindings>();
scrollRoutes.use('*', requireSession());

const TriggerBody = z.object({
  conversationId: z.string().uuid(),
  trigger: z.enum(['user', 'auto']).optional(),
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
  // has a pinned bot we can run on its behalf.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, bot_id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);
  if (!conv.bot_id) {
    return c.json({ error: 'conversation has no bot to write the scroll' }, 400);
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
    }),
  );

  return c.json({ scrollRunId: run.id }, 202);
});

// GET /v1/scroll/list?limit&before
//   Paginated feed of this user's scrolls (newest first). Only completed
//   articles surface — running rows are picked up via Realtime, not list.
//   `before` is an ISO timestamp from the previous page's tail.
scrollRoutes.get('/list', async (c) => {
  const userJwt = c.var.userJwt!;
  const limit = Math.min(50, Math.max(1, Number(c.req.query('limit') ?? 20)));
  const before = c.req.query('before');

  const supa = userClient(c.env, userJwt);
  let q = supa
    .from('scroll_runs')
    .select('id, bot_id, conversation_id, status, title, summary, created_at, finished_at')
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
    .select('id, bot_id, conversation_id, status, title, summary, body_md, progress, created_at, started_at, finished_at')
    .eq('id', id)
    .maybeSingle();
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  if (!data) return c.json({ error: 'not found' }, 404);
  return c.json(data);
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
