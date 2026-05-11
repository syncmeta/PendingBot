import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import type { AppBindings } from '../types';

export const botRoutes = new Hono<AppBindings>();
botRoutes.use('*', requireSession());

const PatchBody = z
  .object({
    // OpenRouter slug. Becomes the bot's new default — applies to every conv
    // with this bot that doesn't have a per-conv pin.
    model_id: z.string().min(1).max(200).optional(),
    // Voice-call gate. When true the iOS conversation header shows the
    // phone button. Bot owner-only — public/preset bots stay locked.
    voice_call_enabled: z.boolean().optional(),
  })
  .refine(
    (v) =>
      v.model_id !== undefined ||
      v.voice_call_enabled !== undefined,
    { message: 'no fields to update' },
  );

// PATCH /v1/bots/:id — owner-only edits to a private bot. Currently
// exposes default model + voice-call gate. Public/preset bots are
// off-limits.
botRoutes.patch('/:id', async (c) => {
  const userId = c.var.userId!;
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

  const supa = serviceClient(c.env);
  const { data: bot, error: botErr } = await supa
    .from('bots')
    .select('id, visibility, creator_id')
    .eq('id', id)
    .maybeSingle();
  if (botErr) return c.json({ error: 'database', detail: botErr.message }, 500);
  if (!bot) return c.json({ error: 'not found' }, 404);
  if (bot.visibility !== 'private' || bot.creator_id !== userId) {
    return c.json({ error: '只能改自己创建的私有机器人' }, 403);
  }

  // Build partial update — only the keys the client actually sent.
  // The Record/never cast covers the partial-builder pattern: each
  // typed key on its own would satisfy the supabase Update generic,
  // but a Record<string, unknown> bag won't unify without help.
  const update: Record<string, unknown> = {
    updated_at: new Date().toISOString(),
  };
  if (parsed.model_id !== undefined) update.model_id = parsed.model_id;
  if (parsed.voice_call_enabled !== undefined)
    update.voice_call_enabled = parsed.voice_call_enabled;
  const { error: updErr } = await supa
    .from('bots')
    .update(update as never)
    .eq('id', id);
  if (updErr) return c.json({ error: 'database', detail: updErr.message }, 500);

  return c.json({ ok: true });
});
