import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { UUID_RE } from '../lib/ids';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const conversationRoutes = new Hono<AppBindings>();
conversationRoutes.use('*', requireSession());

const PatchBody = z.object({
  // OpenRouter slug. `null` clears the per-conv override (turns fall back
  // to the bot's default model). Optional — clients only send the field
  // they're changing.
  model_slug: z.string().min(1).max(200).nullable().optional(),
  // Per-conv vision-model pin (0064). `null` = auto: use main model if it
  // has vision, else DEFAULT_VISION_MODEL. Slug is not validated against
  // capabilities.vision here — the iOS picker already filters that list,
  // and a future operator-curated mismatch would just route normally
  // (read_attachment would fail at the upstream provider, not at the gate).
  vision_model_slug: z.string().min(1).max(200).nullable().optional(),
});

// PATCH /v1/conversations/:id — currently only handles the per-conv model
// pin. Gate: caller must be the conv owner *and* the conv's bot must be a
// private bot owned by the caller. The mobile UI hides the picker for
// public/preset bots; this is the server-side belt.
conversationRoutes.patch('/:id', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) {
    return jsonError(c, 400, 'invalid_id');
  }

  let parsed: z.infer<typeof PatchBody>;
  try {
    parsed = PatchBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // RLS read so a user can't probe other users' convs through this gate.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, bot_id, user_id')
    .eq('id', id)
    .maybeSingle();
  if (convErr) return jsonError(c, 500, 'database_error', { detail: convErr.message });
  if (!conv) return jsonError(c, 404, 'conversation_not_found');
  if (conv.user_id !== userId) return jsonError(c, 403, 'forbidden');
  if (!conv.bot_id) return jsonError(c, 400, 'conversation_has_no_bot');

  const supaService = serviceClient(c.env);
  const { data: bot, error: botErr } = await supaService
    .from('bots')
    .select('id, visibility, creator_id')
    .eq('id', conv.bot_id)
    .single();
  if (botErr || !bot) {
    return jsonError(c, 500, 'database_error', { detail: botErr?.message });
  }
  if (bot.visibility !== 'private' || bot.creator_id !== userId) {
    return jsonError(c, 403, 'forbidden', { message: '只能为自己的私有机器人改模型' });
  }

  // Build the partial update — only set keys the client actually sent.
  // (Sending {model_slug: null} clears the model pin without disturbing
  // vision_model_override, and vice versa.)
  const update: Record<string, string | null> = {};
  if (Object.prototype.hasOwnProperty.call(parsed, 'model_slug')) {
    update.model_slug_override = parsed.model_slug ?? null;
  }
  if (Object.prototype.hasOwnProperty.call(parsed, 'vision_model_slug')) {
    update.vision_model_override = parsed.vision_model_slug ?? null;
  }
  if (Object.keys(update).length === 0) {
    return jsonError(c, 400, 'invalid_body', { message: 'no fields to update' });
  }
  const { error: updErr } = await supaService
    .from('conversations')
    .update(update as never)
    .eq('id', id);
  if (updErr) return jsonError(c, 500, 'database_error', { detail: updErr.message });

  return c.json({ ok: true });
});
