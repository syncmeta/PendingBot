import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import { deleteCachedBot } from '../lib/bot-cache';
import { UUID_RE } from '../lib/ids';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const botRoutes = new Hono<AppBindings>();
botRoutes.use('*', requireSession());

// Bot-level config blob — stored in `bots.config` jsonb. Drives the
// per-bot defaults the conversation resolvers fall back to when a
// conversation carries no override of its own (lookback cadence is
// already consumed by maybeAutoLookback; envelope / vision wired in
// their respective resolvers).
const ConfigPatch = z
  .object({
    lookback: z
      .object({
        enabled: z.boolean().optional(),
        roundInterval: z.number().int().min(1).max(100).optional(),
      })
      .optional(),
    envelope: z
      .object({
        explorerModel: z.string().max(200).optional(),
        collaboratorModel: z.string().max(200).nullable().optional(),
        turnCap: z.number().int().min(1).max(60).optional(),
        historyTokenBudgetPct: z.number().int().min(1).max(100).optional(),
      })
      .optional(),
    visionModel: z.string().max(200).nullable().optional(),
    voiceModel: z.string().max(200).nullable().optional(),
  })
  .strict();

const PatchBody = z
  .object({
    // Model id. Becomes the bot's new default — applies to every conv
    // with this bot that doesn't have a per-conv pin. The string is
    // whatever the picked source's catalog uses (an OpenRouter slug, or
    // an OpenAI model id when model_provider is 'openai').
    model_id: z.string().min(1).max(200).optional(),
    // API route pin — an llm_providers.slug, or null for default routing.
    // Set together with model_id when the user picks from a non-default
    // catalog section (e.g. "OpenAI（原生）").
    model_provider: z.string().max(64).nullable().optional(),
    // Voice-call gate. When true the iOS conversation header shows the
    // phone button. Creator-only — public bots editable too.
    voice_call_enabled: z.boolean().optional(),
    // Partial bot-config patch. Top-level keys present here replace the
    // matching key in the stored `config` jsonb wholesale; absent keys
    // are left untouched.
    config: ConfigPatch.optional(),
  })
  .refine(
    (v) =>
      v.model_id !== undefined ||
      v.model_provider !== undefined ||
      v.voice_call_enabled !== undefined ||
      v.config !== undefined,
    { message: 'no fields to update' },
  );

// PATCH /v1/bots/:id — creator-only edits. Exposes default model +
// voice-call gate + the config blob. The creator keeps this control
// after a bot goes public; only private→public promotion is one-way.
botRoutes.patch('/:id', async (c) => {
  const userId = c.var.userId!;
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

  const supa = serviceClient(c.env);
  const { data: bot, error: botErr } = await supa
    .from('bots')
    .select('id, creator_id, config')
    .eq('id', id)
    .maybeSingle();
  if (botErr) return jsonError(c, 500, 'database_error', { detail: botErr.message });
  if (!bot) return jsonError(c, 404, 'not_found');
  if (bot.creator_id !== userId) {
    return jsonError(c, 403, 'forbidden', { message: '只能改自己创建的机器人' });
  }

  // Build partial update — only the keys the client actually sent.
  // The Record/never cast covers the partial-builder pattern: each
  // typed key on its own would satisfy the supabase Update generic,
  // but a Record<string, unknown> bag won't unify without help.
  const update: Record<string, unknown> = {
    updated_at: new Date().toISOString(),
  };
  if (parsed.model_id !== undefined) update.model_id = parsed.model_id;
  if (parsed.model_provider !== undefined)
    update.model_provider = parsed.model_provider;
  if (parsed.voice_call_enabled !== undefined)
    update.voice_call_enabled = parsed.voice_call_enabled;
  if (parsed.config !== undefined) {
    // Shallow-merge at the top level: the client always sends a
    // complete sub-object for each key it touches, so replacing
    // whole keys (rather than deep-merging) is the intended shape.
    const existing =
      bot.config && typeof bot.config === 'object' && !Array.isArray(bot.config)
        ? (bot.config as Record<string, unknown>)
        : {};
    update.config = { ...existing, ...parsed.config };
  }
  const { error: updErr } = await supa
    .from('bots')
    .update(update as never)
    .eq('id', id);
  if (updErr) return jsonError(c, 500, 'database_error', { detail: updErr.message });

  // Drop the KV entry so the next read pulls fresh values. Cheaper than
  // re-warming the whole row here (the next message request will warm
  // it from Supabase). Failure is non-fatal — the 1h TTL bounds drift.
  await deleteCachedBot(c.env, id).catch(() => undefined);

  return c.json({ ok: true });
});
