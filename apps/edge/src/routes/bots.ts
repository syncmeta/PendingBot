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
    // Model pool. null = use only bot.model_id. An object means new
    // conversations draw their main model from the pool defined by a price
    // range (the slider) ∪ explicit `models`, minus `exclude`.
    modelPool: z
      .object({
        price_min: z.number().nonnegative().nullable().optional(),
        price_max: z.number().nonnegative().nullable().optional(),
        models: z.array(z.string().min(1).max(200)).max(200).nullable().optional(),
        exclude: z.array(z.string().min(1).max(200)).max(200).nullable().optional(),
      })
      .nullable()
      .optional(),
    // Legacy key read by older clients. New clients should write modelPool.
    arena: z
      .object({
        price_min: z.number().nonnegative().nullable().optional(),
        price_max: z.number().nonnegative().nullable().optional(),
        models: z.array(z.string().min(1).max(200)).max(200).nullable().optional(),
        exclude: z.array(z.string().min(1).max(200)).max(200).nullable().optional(),
      })
      .nullable()
      .optional(),
    // OpenRouter `openrouter:web_search` server-tool knobs. Only consumed
    // on the default (OpenRouter) routing path; native-provider bots reach
    // search through their provider's own built-in tools. All fields
    // optional — absent config = search on, engine=auto, no constraints.
    // Maps camelCase here → OpenRouter snake_case params at request build
    // (buildOpenRouterServerTools).
    webSearch: z
      .object({
        enabled: z.boolean().optional(),
        engine: z.enum(['auto', 'native', 'exa', 'firecrawl', 'parallel']).optional(),
        maxResults: z.number().int().min(1).max(25).optional(),
        maxTotalResults: z.number().int().min(1).max(100).optional(),
        searchContextSize: z.enum(['low', 'medium', 'high']).optional(),
        allowedDomains: z.array(z.string().max(253)).max(50).optional(),
        excludedDomains: z.array(z.string().max(253)).max(50).optional(),
      })
      .optional(),
    // Realtime voice call knobs. All optional — absent / null fields fall
    // back to OpenAI defaults at session-mint time. The 8 voices below
    // are the OpenAI Realtime catalog as of 2026-Q2; 'marin' is the
    // worker fallback when voiceId is unset.
    voice: z
      .object({
        voiceId: z
          .enum([
            'alloy',
            'ash',
            'ballad',
            'cedar',
            'coral',
            'echo',
            'marin',
            'sage',
            'shimmer',
            'verse',
          ])
          .nullable()
          .optional(),
        // turn_detection in OpenAI Realtime — server_vad (energy-based,
        // tunable threshold) vs semantic_vad (model decides end-of-turn,
        // tunable eagerness) vs 'none' (push-to-talk; client controls
        // response creation). 'auto' = let OpenAI pick the default
        // (currently semantic_vad).
        turnDetection: z
          .object({
            type: z.enum(['auto', 'server_vad', 'semantic_vad', 'none']).optional(),
            threshold: z.number().min(0).max(1).optional(),
            prefixPaddingMs: z.number().int().min(0).max(2000).optional(),
            silenceDurationMs: z.number().int().min(0).max(2000).optional(),
            eagerness: z.enum(['low', 'medium', 'high', 'auto']).optional(),
            createResponse: z.boolean().optional(),
            interruptResponse: z.boolean().optional(),
          })
          .optional(),
      })
      .optional(),
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
    // Text-chat segmentation. 'bubble' makes the bot split its reply into
    // WeChat-style bubbles (builder injects the `\n---\n` instruction);
    // 'single' is one continuous block. Routed through here (not the iOS
    // direct-supabase edit) so the KV bot-cache is busted immediately and
    // the toggle takes effect on the very next turn.
    output_mode: z.enum(['single', 'bubble']).optional(),
    // IANA timezone for this bot. Only meaningful for public bots — group
    // dispatch uses it as the time-hint tz and builder injects it into
    // the system prompt as "你所在的时区是 X". Sending '' (empty) clears
    // it back to NULL; iOS does that when promoting public→private,
    // though that path doesn't actually exist in the UI today.
    tz: z.string().max(64).optional(),
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
      v.output_mode !== undefined ||
      v.tz !== undefined ||
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
  if (parsed.output_mode !== undefined) update.output_mode = parsed.output_mode;
  if (parsed.tz !== undefined) update.tz = parsed.tz === '' ? null : parsed.tz;
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
