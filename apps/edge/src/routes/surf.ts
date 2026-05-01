import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runSurf } from '../lib/surf-runner';
import type { AppBindings } from '../types';

export const surfRoutes = new Hono<AppBindings>();
surfRoutes.use('*', requireSession());

const StartBody = z.object({
  conversationId: z.string().uuid(),
  query: z.string().min(1).max(8_000),
  trigger: z.enum(['user', 'auto', 'panel']).optional(),
});

// POST /v1/surf/start — kicks off a long-running surf agent against the
// given (typically conversation_type='surf') conversation. Returns the
// surf_runs id immediately; progress lands via Realtime on the conv channel.
surfRoutes.post('/start', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof StartBody>;
  try {
    parsed = StartBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // RLS-gate the conversation membership.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);

  const supa = serviceClient(c.env);
  const { data: run, error: runErr } = await supa
    .from('surf_runs')
    .insert({
      conversation_id: parsed.conversationId,
      user_id: userId,
      status: 'running',
      trigger: parsed.trigger ?? 'user',
      progress: { phase: 'queued', query: parsed.query },
    })
    .select('id')
    .single();
  if (runErr || !run) {
    return c.json({ error: 'database', detail: runErr?.message ?? 'insert failed' }, 500);
  }

  c.executionCtx.waitUntil(
    runSurf({
      env: c.env,
      surfRunId: run.id as string,
      conversationId: parsed.conversationId,
      userId,
      query: parsed.query,
    }),
  );

  return c.json({ surfRunId: run.id }, 202);
});

// POST /v1/surf/:id/cancel — flip status to 'cancelled'. The runner reads
// this on its next poll cycle (B7 will add the polling; for now stub
// runners just respect the row state on next phase).
surfRoutes.post('/:id/cancel', async (c) => {
  const id = c.req.param('id');
  const userJwt = c.var.userJwt!;
  // Use user client so RLS validates ownership.
  const supa = userClient(c.env, userJwt);
  const { error } = await supa
    .from('surf_runs')
    .update({ status: 'cancelled', finished_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ ok: true });
});
