import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runReview } from '../lib/review-runner';
import { requireBalance, InsufficientBalanceError } from '../lib/billing';
import type { AppBindings } from '../types';

export const reviewRoutes = new Hono<AppBindings>();
reviewRoutes.use('*', requireSession());

const TriggerBody = z.object({
  conversationId: z.string().uuid(),
  trigger: z.enum(['user', 'auto']).optional(),
});

// POST /v1/review/trigger — start a review against a chat conversation.
// Review surfaces directly in the host conv via role='log' messages
// (review:step / review:card / review:closing); no separate review conv.
reviewRoutes.post('/trigger', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof TriggerBody>;
  try {
    parsed = TriggerBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, bot_id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);
  if (!conv.bot_id) {
    return c.json({ error: 'conversation has no pinned bot to review' }, 400);
  }

  // Billing gate.
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
    .from('review_runs')
    .insert({
      conversation_id: parsed.conversationId,
      user_id: userId,
      bot_id: conv.bot_id,
      status: 'running',
      trigger: parsed.trigger ?? 'user',
    })
    .select('id')
    .single();
  if (runErr || !run) {
    return c.json({ error: 'database', detail: runErr?.message ?? 'insert failed' }, 500);
  }

  c.executionCtx.waitUntil(
    runReview({
      env: c.env,
      reviewRunId: run.id as string,
      conversationId: parsed.conversationId,
      userId,
      botId: conv.bot_id as string,
    }),
  );

  return c.json({ reviewRunId: run.id }, 202);
});
