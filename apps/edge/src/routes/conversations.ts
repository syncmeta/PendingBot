import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import type { AppBindings } from '../types';

export const conversationRoutes = new Hono<AppBindings>();
conversationRoutes.use('*', requireSession());

const PatchBody = z.object({
  // OpenRouter slug. `null` clears the per-conv override (turns fall back
  // to the bot's default model).
  model_slug: z.string().min(1).max(200).nullable(),
});

// PATCH /v1/conversations/:id — currently only handles the per-conv model
// pin. Gate: caller must be the conv owner *and* the conv's bot must be a
// private bot owned by the caller. The mobile UI hides the picker for
// public/preset bots; this is the server-side belt.
conversationRoutes.patch('/:id', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const id = c.req.param('id');
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return c.json({ error: 'invalid id' }, 400);
  }

  let parsed: z.infer<typeof PatchBody>;
  try {
    parsed = PatchBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // RLS read so a user can't probe other users' convs through this gate.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, bot_id, user_id')
    .eq('id', id)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'not found' }, 404);
  if (conv.user_id !== userId) return c.json({ error: 'forbidden' }, 403);
  if (!conv.bot_id) return c.json({ error: 'conv has no bot' }, 400);

  const supaService = serviceClient(c.env);
  const { data: bot, error: botErr } = await supaService
    .from('bots')
    .select('id, visibility, creator_id')
    .eq('id', conv.bot_id)
    .single();
  if (botErr || !bot) {
    return c.json({ error: 'bot lookup failed', detail: botErr?.message }, 500);
  }
  if (bot.visibility !== 'private' || bot.creator_id !== userId) {
    return c.json({ error: '只能为自己的私有机器人改模型' }, 403);
  }

  const { error: updErr } = await supaService
    .from('conversations')
    .update({ model_slug_override: parsed.model_slug })
    .eq('id', id);
  if (updErr) return c.json({ error: 'database', detail: updErr.message }, 500);

  return c.json({ ok: true });
});
