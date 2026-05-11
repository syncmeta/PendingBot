// Voice call HTTP surface (M5+). Two providers, one route file:
//
//   POST /v1/realtime/session      — mint provider creds + bot system prompt
//   POST /v1/realtime/usage        — per-turn audit + debit + balance gate
//   POST /v1/realtime/transcripts  — write turn rows to messages
//   POST /v1/realtime/end          — close session (no-op for openai, optional
//                                    audit marker for doubao)
//
// The worker never proxies the audio. iOS connects directly:
//   OpenAI → WebRTC SDP exchange to https://api.openai.com/v1/realtime
//   Doubao → SpeechEngineToB SDK opens wss://openspeech.bytedance.com/...
//
// All four endpoints require a Supabase JWT (requireSession) and re-verify
// caller ↔ conversation ownership on every call so a leaked session_id
// can't be abused cross-account.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { getBalance, getConfigInt } from '../lib/billing';
import { resolveRoute, recordAudit } from '../llm/router';
import { buildSystemPrompt, type BuildSystemPromptInput } from '../llm/builder';
import { getBotMemory, getChatMemo } from '../lib/memory';
import { resolveLocale } from '../i18n/locale';
import { t } from '../i18n/index';
import {
  checkOpenAIRegion,
  OPENAI_SUPPORTED_URL,
} from '../lib/openai-regions';
import type { AppBindings } from '../types';

export const realtimeRoutes = new Hono<AppBindings>();
realtimeRoutes.use('*', requireSession());

// =============================================================================
// shared helpers
// =============================================================================

// 36-char UUID guard — same shape as conversation/bot ids elsewhere.
const UUID_RE = /^[0-9a-f-]{36}$/i;

// One source of truth for the model slugs the realtime route understands;
// task_routing_rules lookup is keyed off these in resolveRoute(...,
// taskType: 'voice_call'). Provider columns on bots constrain which slug
// gets selected per call.
const OPENAI_MODEL_SLUG = 'gpt-realtime';
const DOUBAO_MODEL_SLUG = 'doubao-realtime';

const PROVIDERS = ['openai', 'doubao'] as const;
type VoiceProvider = (typeof PROVIDERS)[number];

interface SessionContext {
  userId: string;
  userJwt: string;
  locale: Awaited<ReturnType<typeof resolveLocale>>;
  conversation: { id: string; bot_id: string; user_id: string };
  bot: {
    id: string;
    display_name: string;
    output_mode: string;
    voice_call_enabled: boolean;
    voice_call_provider: VoiceProvider;
  };
}

/**
 * Load the conversation (RLS-scoped) and the bot (service-scoped so the
 * voice-call flags are visible even if RLS hides them from the caller).
 * Returns an HTTP-shaped error tuple `{status, body}` ready to pass to
 * `c.json(body, status)` for the four 4xx cases.
 */
async function loadSessionContext(
  env: AppBindings['Bindings'],
  userId: string,
  userJwt: string,
  conversationId: string,
  locale: Awaited<ReturnType<typeof resolveLocale>>,
): Promise<
  | { ok: true; ctx: SessionContext }
  | { ok: false; status: 400 | 403 | 404; body: Record<string, unknown> }
> {
  if (!UUID_RE.test(conversationId)) {
    return {
      ok: false,
      status: 400,
      body: { error: 'invalid_conversation_id' },
    };
  }
  const supaUser = userClient(env, userJwt);
  const { data: conv } = await supaUser
    .from('conversations')
    .select('id, bot_id, user_id, conversation_type')
    .eq('id', conversationId)
    .maybeSingle();
  if (!conv || conv.user_id !== userId) {
    return {
      ok: false,
      status: 404,
      body: { error: 'conversation_not_found', message: t('voice.conversation_not_found', locale) },
    };
  }
  if (conv.conversation_type !== 'user_bot' || !conv.bot_id) {
    return {
      ok: false,
      status: 400,
      body: { error: 'not_user_bot_conversation' },
    };
  }
  const supaService = serviceClient(env);
  // bots.voice_call_enabled / voice_call_provider are new columns; schema.ts
  // hasn't been regen'd, so the select string is cast to never for now.
  const { data: bot } = await supaService
    .from('bots')
    .select(
      'id, display_name, output_mode, voice_call_enabled, voice_call_provider' as never,
    )
    .eq('id', conv.bot_id)
    .maybeSingle();
  if (!bot) {
    return {
      ok: false,
      status: 404,
      body: { error: 'bot_not_found' },
    };
  }
  const botRow = bot as unknown as {
    id: string;
    display_name: string;
    output_mode: string;
    voice_call_enabled: boolean | null;
    voice_call_provider: string | null;
  };
  if (!botRow.voice_call_enabled) {
    return {
      ok: false,
      status: 403,
      body: { error: 'voice_call_disabled', message: t('voice.bot_not_enabled', locale) },
    };
  }
  const provider = botRow.voice_call_provider;
  if (provider !== 'openai' && provider !== 'doubao') {
    return {
      ok: false,
      status: 400,
      body: { error: 'invalid_provider', message: t('voice.invalid_provider', locale) },
    };
  }
  return {
    ok: true,
    ctx: {
      userId,
      userJwt,
      locale,
      conversation: { id: conv.id, bot_id: conv.bot_id, user_id: conv.user_id },
      bot: {
        id: botRow.id,
        display_name: botRow.display_name,
        output_mode: botRow.output_mode,
        voice_call_enabled: true,
        voice_call_provider: provider,
      },
    },
  };
}

/**
 * Load the bot's persona context (memory, skills, bot-note, chat-memo,
 * lookbacks) and run it through the existing builder. Result is the same
 * system prompt string text turns get, ready to drop into OpenAI's
 * `instructions` field or Doubao's StartSession `dialog.system_role`.
 */
async function assembleInstructions(
  env: AppBindings['Bindings'],
  ctx: SessionContext,
): Promise<string> {
  const supa = serviceClient(env);
  const [botMemory, skillsRes, botNoteRes, chatMemo, lookbacksRes] =
    await Promise.all([
      getBotMemory(env, ctx.bot.id),
      supa
        .from('skill_subscriptions')
        .select('skills(frontmatter, body_md)')
        .eq('user_id', ctx.userId)
        .or(`conversation_id.eq.${ctx.conversation.id},conversation_id.is.null`),
      supa
        .from('skills')
        .select('body_md')
        .eq('bot_id', ctx.bot.id)
        .eq('user_id', ctx.userId)
        .maybeSingle(),
      getChatMemo(env, ctx.bot.id, ctx.conversation.id),
      supa
        .from('bot_lookbacks')
        .select('id, body_md')
        .eq('bot_id', ctx.bot.id)
        .eq('conversation_id', ctx.conversation.id)
        .eq('active', true)
        .order('created_at', { ascending: true }),
    ]);

  type SkillRow = {
    frontmatter: { name?: string; description?: string };
    body_md: string;
  };
  const skills: Array<{ name: string; description: string; body: string }> = [];
  for (const row of skillsRes.data ?? []) {
    const joined = (row as { skills: SkillRow | SkillRow[] | null }).skills;
    const arr = Array.isArray(joined) ? joined : joined ? [joined] : [];
    for (const s of arr) {
      skills.push({
        name: s.frontmatter?.name ?? 'unnamed',
        description: s.frontmatter?.description ?? '',
        body: s.body_md,
      });
    }
  }
  const botNote = (botNoteRes.data?.body_md as string | undefined) ?? null;
  const lookbacks = (lookbacksRes.data ?? []).map(
    (r) => r as { id: string; body_md: string },
  );

  const sysInput: BuildSystemPromptInput = {
    bot: {
      id: ctx.bot.id,
      display_name: ctx.bot.display_name,
      output_mode: ctx.bot.output_mode,
    } as never,
    botMemory,
    skills,
    botNote,
    chatMemo,
    lookbacks,
    // Voice calls don't carry images yet — leave the inventory undefined
    // so the section drops out of the assembled prompt entirely.
  };
  return buildSystemPrompt(supa, sysInput, ctx.locale);
}

// =============================================================================
// POST /v1/realtime/session
// =============================================================================

const SessionBody = z.object({
  conversation_id: z.string(),
});

realtimeRoutes.post('/session', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);
  const locale = await resolveLocale(c.req.raw, supaUser, userId);

  let parsed: z.infer<typeof SessionBody>;
  try {
    parsed = SessionBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid_body', detail: String(err) }, 400);
  }

  const loaded = await loadSessionContext(
    c.env,
    userId,
    userJwt,
    parsed.conversation_id,
    locale,
  );
  if (!loaded.ok) return c.json(loaded.body, loaded.status);
  const ctx = loaded.ctx;

  // Balance gate. Compare integer credits to the configured threshold;
  // 0 / null disables the gate (matches text-turn behavior).
  const [balance, threshold] = await Promise.all([
    getBalance(supaUser, userId),
    getConfigInt(supaUser, 'min_balance_threshold'),
  ]);
  const minThreshold = threshold ?? 0;
  const balanceCredits = balance?.balance_credits ?? 0;
  if (minThreshold > 0 && balanceCredits < minThreshold) {
    return c.json(
      {
        error: 'insufficient_balance',
        message: t('voice.insufficient_balance', locale),
        balance_credits: balanceCredits,
        min_threshold: minThreshold,
      },
      402,
    );
  }

  // OpenAI-only: region gate (Doubao serves CN natively).
  if (ctx.bot.voice_call_provider === 'openai') {
    const cfCountry = (c.req.raw as unknown as { cf?: { country?: string } }).cf
      ?.country;
    const region = checkOpenAIRegion(cfCountry ?? null);
    if (!region.allowed) {
      return c.json(
        {
          error: 'region_unsupported',
          country: region.country,
          message: t('voice.region_unsupported', locale),
          supported_url: OPENAI_SUPPORTED_URL,
        },
        451,
      );
    }
  }

  // Persona — same string both providers consume.
  const instructions = await assembleInstructions(c.env, ctx);

  // Route resolution gives us alias + provider rows from llm_model_aliases.
  // The model slug is fixed per provider here; task_routing_rules can still
  // override at admin discretion via taskType='voice_call'.
  const modelSlug =
    ctx.bot.voice_call_provider === 'openai'
      ? OPENAI_MODEL_SLUG
      : DOUBAO_MODEL_SLUG;
  let route;
  try {
    route = await resolveRoute(supaUser, c.env, {
      modelSlug,
      taskType: 'voice_call',
    });
  } catch (err) {
    console.warn('[realtime/session] resolveRoute failed', err);
    return c.json(
      { error: 'route_unavailable', message: t('voice.upstream_failed', locale) },
      503,
    );
  }

  const sessionId = crypto.randomUUID();

  if (ctx.bot.voice_call_provider === 'openai') {
    return await mintOpenAISession(c.env, locale, {
      sessionId,
      route,
      instructions,
      balanceCredits,
      minThreshold,
    });
  }

  return mintDoubaoSession(c.env, locale, {
    sessionId,
    route,
    instructions,
    bot: ctx.bot,
    userId,
    balanceCredits,
    minThreshold,
  });
});

interface MintArgs {
  sessionId: string;
  route: Awaited<ReturnType<typeof resolveRoute>>;
  instructions: string;
  balanceCredits: number;
  minThreshold: number;
}

async function mintOpenAISession(
  env: AppBindings['Bindings'],
  locale: Awaited<ReturnType<typeof resolveLocale>>,
  args: MintArgs,
) {
  if (!env.OPENAI_API_KEY) {
    return jsonError(
      503,
      'route_unavailable',
      t('voice.upstream_failed', locale),
    );
  }
  // OpenAI Realtime: POST /v1/realtime/sessions returns a short-lived
  // client_secret (~60s) the iOS WebRTC layer carries as a Bearer when
  // it does the SDP exchange. We never see the audio.
  let upstream: Response;
  try {
    upstream = await fetch('https://api.openai.com/v1/realtime/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: args.route.modelToCall,
        voice: 'alloy',
        instructions: args.instructions,
        input_audio_format: 'pcm16',
        output_audio_format: 'pcm16',
        // Whisper-based user transcript so iOS can collect both halves
        // of the conversation for the post-call /transcripts upload.
        input_audio_transcription: { model: 'whisper-1' },
      }),
    });
  } catch (err) {
    console.warn('[realtime/session] openai fetch failed', err);
    return jsonError(503, 'route_unavailable', t('voice.upstream_failed', locale));
  }
  if (!upstream.ok) {
    const body = await upstream.text();
    console.warn('[realtime/session] openai non-2xx', upstream.status, body.slice(0, 300));
    return jsonError(
      upstream.status === 429 ? 429 : 502,
      'upstream_error',
      t('voice.upstream_failed', locale),
    );
  }
  const data = (await upstream.json()) as {
    id?: string;
    client_secret?: { value?: string; expires_at?: number };
    model?: string;
  };
  const clientSecret = data.client_secret?.value;
  if (!clientSecret) {
    console.warn('[realtime/session] openai response missing client_secret', data);
    return jsonError(502, 'upstream_error', t('voice.upstream_failed', locale));
  }
  return Response.json({
    provider: 'openai' as const,
    session_id: args.sessionId,
    client_secret: {
      value: clientSecret,
      expires_at: data.client_secret?.expires_at ?? null,
    },
    model: data.model ?? args.route.modelToCall,
    alias_id: args.route.alias?.aliasId ?? null,
    provider_id: args.route.provider.id,
    min_threshold: args.minThreshold,
    balance_credits: args.balanceCredits,
  });
}

interface DoubaoMintArgs extends MintArgs {
  bot: SessionContext['bot'];
  userId: string;
}

function mintDoubaoSession(
  env: AppBindings['Bindings'],
  locale: Awaited<ReturnType<typeof resolveLocale>>,
  args: DoubaoMintArgs,
) {
  // The Doubao SDK opens its own WebSocket from the device; the worker's
  // job is just to forward the static console-issued credentials together
  // with the persona text. AppKey leaving the worker is the upstream's
  // design (SE_PARAMS_KEY_APP_KEY_STRING is a client-side parameter); we
  // gate on auth + balance + bot.voice_call_enabled before sending.
  const { DOUBAO_DIALOG_APP_ID, DOUBAO_DIALOG_APP_KEY, DOUBAO_DIALOG_ACCESS_TOKEN } = env;
  if (!DOUBAO_DIALOG_APP_ID || !DOUBAO_DIALOG_APP_KEY || !DOUBAO_DIALOG_ACCESS_TOKEN) {
    return jsonError(503, 'route_unavailable', t('voice.upstream_failed', locale));
  }
  // Deterministic device-side uid built from the supabase user_id. The
  // upstream uses this for log correlation and per-user throttling.
  const uid = `pb_${args.userId.slice(0, 8)}_${args.sessionId.slice(0, 8)}`;
  return Response.json({
    provider: 'doubao' as const,
    session_id: args.sessionId,
    model: args.route.modelToCall,
    alias_id: args.route.alias?.aliasId ?? null,
    provider_id: args.route.provider.id,
    min_threshold: args.minThreshold,
    balance_credits: args.balanceCredits,
    doubao: {
      app_id: DOUBAO_DIALOG_APP_ID,
      app_key: DOUBAO_DIALOG_APP_KEY,
      access_token: DOUBAO_DIALOG_ACCESS_TOKEN,
      resource_id: 'volc.speech.dialog',
      dialog_address: 'wss://openspeech.bytedance.com',
      dialog_uri: '/api/v3/realtime/dialogue',
      uid,
      bot_name: args.bot.display_name,
      system_prompt: args.instructions,
    },
  });
}

function jsonError(status: number, error: string, message: string) {
  return Response.json({ error, message }, { status });
}

// =============================================================================
// POST /v1/realtime/usage — per-turn audit + debit + balance gate
// =============================================================================

const UsageBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
  alias_id: z.string().nullable().optional(),
  provider_id: z.string(),
  provider: z.enum(PROVIDERS),
  // OpenAI dims (per-turn deltas pulled from response.done.usage)
  audio_input_tokens: z.number().int().min(0).optional(),
  audio_output_tokens: z.number().int().min(0).optional(),
  text_input_tokens: z.number().int().min(0).optional(),
  text_output_tokens: z.number().int().min(0).optional(),
  // Doubao dim (seconds elapsed since last tick)
  audio_seconds_billed: z.number().min(0).optional(),
  latency_ms: z.number().int().min(0).optional(),
  turn_index: z.number().int().min(0),
});

realtimeRoutes.post('/usage', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);
  const locale = await resolveLocale(c.req.raw, supaUser, userId);

  let parsed: z.infer<typeof UsageBody>;
  try {
    parsed = UsageBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid_body', detail: String(err) }, 400);
  }

  const loaded = await loadSessionContext(
    c.env,
    userId,
    userJwt,
    parsed.conversation_id,
    locale,
  );
  if (!loaded.ok) return c.json(loaded.body, loaded.status);

  // Re-resolve the route so recordAudit gets fresh pricing — admin may
  // have tweaked audio_*_price between session start and this tick.
  // Note: this means a mid-call price edit takes effect on the next turn,
  // which is exactly the propagation latency users expect from the board.
  const modelSlug =
    parsed.provider === 'openai' ? OPENAI_MODEL_SLUG : DOUBAO_MODEL_SLUG;
  let route;
  try {
    route = await resolveRoute(supaUser, c.env, {
      modelSlug,
      taskType: 'voice_call',
      preferProvider: parsed.provider,
    });
  } catch (err) {
    console.warn('[realtime/usage] resolveRoute failed', err);
    return c.json({ error: 'route_unavailable' }, 503);
  }

  const startedAt = Date.now();
  await recordAudit(supaUser, route, {
    userId,
    conversationId: parsed.conversation_id,
    taskType: 'voice_call',
    startedAt,
    status: 'success',
    inputTokens: parsed.text_input_tokens ?? 0,
    outputTokens: parsed.text_output_tokens ?? 0,
    audioInputTokens: parsed.audio_input_tokens ?? 0,
    audioOutputTokens: parsed.audio_output_tokens ?? 0,
    audioSecondsBilled: parsed.audio_seconds_billed,
    metadata: {
      source: 'voice_call',
      session_id: parsed.session_id,
      provider: parsed.provider,
      turn_index: parsed.turn_index,
      ...(parsed.latency_ms != null ? { latency_ms: parsed.latency_ms } : {}),
    },
    env: c.env,
  });

  // Re-read balance + session cumulative cost. recordAudit handled the
  // debit on the same supa client; the row is now visible.
  const [balanceAfter, threshold, sessionAggRes] = await Promise.all([
    getBalance(supaUser, userId),
    getConfigInt(supaUser, 'min_balance_threshold'),
    supaUser
      .from('audit_log')
      .select('cost_credits, metadata')
      .eq('task_type', 'voice_call')
      .eq('user_id', userId)
      .filter('metadata->>session_id', 'eq', parsed.session_id),
  ]);

  const balanceCredits = balanceAfter?.balance_credits ?? 0;
  const minThreshold = threshold ?? 0;
  const sessionRows = (sessionAggRes.data ?? []) as Array<{
    cost_credits: number | null;
  }>;
  const sessionCostCredits = sessionRows.reduce(
    (s, r) => s + (Number(r.cost_credits) || 0),
    0,
  );
  // Approximate turn cost as "total at this session, minus what it was
  // before this insert" — we don't ledger by-turn separately. Negative
  // is impossible here since recordAudit only adds. Fall back to 0 when
  // the alias has no audio pricing (e.g. doubao with audio_per_minute
  // null in the alias table).
  const turnCost = sessionRows.length > 0
    ? Number(sessionRows[sessionRows.length - 1]?.cost_credits) || 0
    : 0;

  return c.json({
    balance_credits: balanceCredits,
    turn_cost_credits: turnCost,
    session_cost_credits: sessionCostCredits,
    can_continue: minThreshold === 0 || balanceCredits >= minThreshold,
  });
});

// =============================================================================
// POST /v1/realtime/transcripts — write turn rows into messages
// =============================================================================

const TranscriptBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
  turns: z
    .array(
      z.object({
        role: z.enum(['user', 'bot']),
        content: z.string().min(1),
        ts: z.string(),
      }),
    )
    .max(500),
});

realtimeRoutes.post('/transcripts', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);
  const locale = await resolveLocale(c.req.raw, supaUser, userId);

  let parsed: z.infer<typeof TranscriptBody>;
  try {
    parsed = TranscriptBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid_body', detail: String(err) }, 400);
  }

  const loaded = await loadSessionContext(
    c.env,
    userId,
    userJwt,
    parsed.conversation_id,
    locale,
  );
  if (!loaded.ok) return c.json(loaded.body, loaded.status);
  const ctx = loaded.ctx;
  if (parsed.turns.length === 0) return c.json({ inserted: 0 });

  // Sort by ts ascending so the bubble order matches the live call. The
  // client should already send them in order but a defensive sort is cheap.
  const sortedTurns = [...parsed.turns].sort((a, b) =>
    a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0,
  );

  const supaService = serviceClient(c.env);
  const rows = sortedTurns.map((t, idx) => ({
    conversation_id: parsed.conversation_id,
    client_message_id: `voice:${parsed.session_id}:${idx}`,
    role: t.role,
    status: 'done',
    content: t.content,
    user_id: t.role === 'user' ? ctx.userId : null,
    sender_bot_id: t.role === 'bot' ? ctx.bot.id : null,
    metadata: {
      source: 'voice_call',
      session_id: parsed.session_id,
      turn_index: idx,
      ts: t.ts,
    },
  }));
  // Cast: schema.ts hasn't been regen'd for the new messages.metadata
  // column yet; the cast clears once the user applies the migration.
  const { error } = await supaService
    .from('messages')
    .insert(rows as never);
  if (error) {
    console.warn('[realtime/transcripts] insert failed', error.message);
    return c.json({ error: 'database', detail: error.message }, 500);
  }
  return c.json({ inserted: rows.length });
});

// =============================================================================
// POST /v1/realtime/end — session terminator
// =============================================================================
//
// OpenAI: no-op (client disconnect ends the session; ephemeral key expires
// on its own).
// Doubao: no-op too — the SDK closes its WebSocket when iOS calls
// SyncStopEngine, there is no server-side task to stop.
//
// Endpoint exists so the iOS client can issue one uniform call after the
// transcripts upload, and so we have an extension point for any future
// per-session cleanup (e.g. webhook acks, cron-friendly markers).
const EndBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
});

realtimeRoutes.post('/end', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);
  const locale = await resolveLocale(c.req.raw, supaUser, userId);

  let parsed: z.infer<typeof EndBody>;
  try {
    parsed = EndBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid_body', detail: String(err) }, 400);
  }
  const loaded = await loadSessionContext(
    c.env,
    userId,
    userJwt,
    parsed.conversation_id,
    locale,
  );
  if (!loaded.ok) return c.json(loaded.body, loaded.status);
  return c.json({ ok: true });
});
