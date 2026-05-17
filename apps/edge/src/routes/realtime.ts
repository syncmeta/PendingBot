// Voice call HTTP surface (M5+). One provider — OpenAI Realtime.
//
//   POST /v1/realtime/session      — mint ephemeral client_secret + bake
//                                    bot system prompt server-side
//   POST /v1/realtime/attach       — hand the call_id to the server-side meter
//   POST /v1/realtime/summary      — store the model's closing recap of the
//                                    call as a memory-only message row
//   POST /v1/realtime/end          — close session (stops the meter DO)
//
// The worker never proxies the audio. The system prompt is sent to OpenAI
// during the mint step (POST /v1/realtime/client_secrets) and baked into
// the session; only the ephemeral 60s client_secret reaches iOS, which
// uses it for the WebRTC SDP exchange against api.openai.com/v1/realtime/calls.
//
// All four endpoints require a Supabase JWT (requireSession) and re-verify
// caller ↔ conversation ownership on every call so a leaked session_id
// can't be abused cross-account.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { getBalance, getConfigInt } from '../lib/billing';
import { resolveRoute } from '../llm/router';
import { buildSystemPrompt, type BuildSystemPromptInput } from '../llm/builder';
import { getBotMemory, getChatMemo } from '../lib/memory';
import { resolveLocale } from '../i18n/locale';
import { t } from '../i18n/index';
import type { Json } from '../db/schema';
import { UUID_RE } from '../lib/ids';
import {
  endRealtimeSession,
  recordRealtimeSession,
  requireActiveSession,
} from '../lib/realtime-sessions';
import { jsonError as routeJsonError, type ApiErrorCode } from '../lib/http-error';
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

// Default voice model slug — used when the client sends no `model`.
// The iOS picker's values double as model slugs (gpt-realtime-2 /
// gpt-realtime-mini-2025-12-15), so a picked model resolves and prices
// directly; this is just the fallback for an absent pick.
const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';

interface SessionContext {
  userId: string;
  userJwt: string;
  locale: Awaited<ReturnType<typeof resolveLocale>>;
  conversation: { id: string; bot_id: string; user_id: string };
  bot: {
    id: string;
    display_name: string;
    output_mode: 'single' | 'bubble';
    voice_call_enabled: boolean;
    /// Bot-level default realtime model (bots.config.voiceModel). Used
    /// as the mint `model` when the client picker didn't send one.
    voice_model: string | null;
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
  const { data: bot } = await supaService
    .from('bots')
    .select('id, display_name, output_mode, voice_call_enabled, config')
    .eq('id', conv.bot_id)
    .maybeSingle();
  if (!bot) {
    return {
      ok: false,
      status: 404,
      body: { error: 'bot_not_found' },
    };
  }
  if (!bot.voice_call_enabled) {
    return {
      ok: false,
      status: 403,
      body: { error: 'voice_call_disabled', message: t('voice.bot_not_enabled', locale) },
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
        id: bot.id,
        display_name: bot.display_name,
        // CHECK constraint on bots.output_mode permits exactly these two;
        // schema.ts types the column as plain `string` so we narrow here.
        output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
        voice_call_enabled: true,
        voice_model: ((): string | null => {
          const cfg = bot.config;
          if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) return null;
          const v = (cfg as Record<string, unknown>).voiceModel;
          return typeof v === 'string' && v.length > 0 ? v : null;
        })(),
      },
    },
  };
}

/**
 * Load the bot's persona context (memory, skills, bot-note, chat-memo,
 * lookbacks) and run it through the existing builder. Returns the same
 * system prompt string text turns get, ready to drop into OpenAI's
 * `instructions` field at session-mint time.
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
      output_mode: ctx.bot.output_mode,
    },
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
  // 'webrtc' (default) — direct iOS<->OpenAI WebRTC, lowest latency,
  // region-gated. 'websocket' — audio relayed iOS<->worker<->OpenAI,
  // egresses from Cloudflare so it works from regions OpenAI geo-blocks.
  // The client picks.
  transport: z.enum(['webrtc', 'websocket']).default('webrtc'),
  // Optional voice model override (client picker). When set it's sent
  // straight to OpenAI's mint as the realtime `model`; when absent the
  // resolved route's model id is used.
  model: z.string().min(1).optional(),
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
    return routeJsonError(c, 400, 'invalid_body', { detail: String(err) });
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
    return routeJsonError(c, 402, 'insufficient_balance', {
      message: t('voice.insufficient_balance', locale),
      detail: {
        balance_credits: balanceCredits,
        min_threshold: minThreshold,
      },
    });
  }

  // Persona assembled server-side. For WebRTC it's baked into the
  // ephemeral mint body; for WebSocket the meter DO sends it via
  // session.update. Either way it never touches the iOS device.
  const instructions = await assembleInstructions(c.env, ctx);

  // Route resolution keyed on the client-picked voice model (its picker
  // value is the model slug); task_routing_rules can still override at
  // admin discretion via taskType='voice_call'. Uses the service client,
  // not supaUser — the llm_* config tables are RLS-locked (RLS on, no
  // policy = deny for authenticated), so a user JWT reads zero rows.
  let route;
  try {
    route = await resolveRoute(serviceClient(c.env), c.env, {
      modelSlug: parsed.model ?? DEFAULT_VOICE_MODEL_SLUG,
      taskType: 'voice_call',
      metadata: { userId, conversationId: parsed.conversation_id },
    });
  } catch (err) {
    console.warn('[realtime/session] resolveRoute failed', err);
    return c.json(
      { error: { code: 'voice_upstream_failed', message: t('voice.upstream_failed', locale) } },
      503,
    );
  }

  const sessionId = crypto.randomUUID();

  if (parsed.transport === 'websocket') {
    // WebSocket transport: audio is relayed iOS<->worker<->OpenAI by
    // RealtimeMeterDO. The connection egresses from Cloudflare, not the
    // user's device, so the OpenAI region gate does NOT apply — skip it.
    await recordRealtimeSession(c.env, {
      session_id: sessionId,
      user_id: userId,
      conversation_id: parsed.conversation_id,
      bot_id: ctx.bot.id,
      openai_session_id: null,
    });
    const meterId = c.env.REALTIME_METER.idFromName(sessionId);
    const prep = await c.env.REALTIME_METER.get(meterId).fetch(
      'https://meter.internal/prepare',
      {
        method: 'POST',
        body: JSON.stringify({
          transport: 'proxy',
          sessionId,
          userId,
          conversationId: parsed.conversation_id,
          botId: ctx.bot.id,
          startedAt: Date.now(),
          model: route.modelToCall,
          instructions,
        }),
      },
    );
    if (!prep.ok) {
      console.warn('[realtime/session] meter prepare failed', prep.status);
      return routeJsonError(c, 503, 'voice_upstream_failed');
    }
    return c.json({
      session_id: sessionId,
      transport: 'websocket',
      ws_path: `/v1/realtime/ws?session_id=${sessionId}`,
      model: route.modelToCall,
      alias_id: route.alias?.aliasId ?? null,
      provider_id: route.provider.id,
      min_threshold: minThreshold,
      balance_credits: balanceCredits,
    });
  }

  // WebRTC transport (default). Region gate applies — iOS connects to
  // OpenAI directly, so a geo-blocked egress IP must be rejected here.
  // cf.country is Cloudflare's edge GeoIP for the request's egress IP;
  // the blocked list lives in lib/openai-regions.ts.
  const cfCountry = (c.req.raw as unknown as { cf?: { country?: string } }).cf
    ?.country;
  const region = checkOpenAIRegion(cfCountry ?? null);
  if (!region.allowed) {
    return routeJsonError(c, 451, 'voice_region_unsupported', {
      message: t('voice.region_unsupported', locale),
      detail: {
        country: region.country,
        supported_url: OPENAI_SUPPORTED_URL,
      },
    });
  }
  return await mintOpenAISession(c.env, locale, {
    sessionId,
    userId,
    conversationId: parsed.conversation_id,
    botId: ctx.bot.id,
    route,
    instructions,
    balanceCredits,
    minThreshold,
    // Client picker wins; otherwise the bot's configured default
    // realtime model (bots.config.voiceModel), else the resolved route.
    modelOverride: parsed.model ?? ctx.bot.voice_model ?? undefined,
  });
});

interface MintArgs {
  sessionId: string;
  userId: string;
  conversationId: string;
  botId: string;
  route: Awaited<ReturnType<typeof resolveRoute>>;
  instructions: string;
  balanceCredits: number;
  minThreshold: number;
  /// Client-picked realtime model id. Overrides route.modelToCall in the
  /// mint body when set.
  modelOverride?: string;
}

async function mintOpenAISession(
  env: AppBindings['Bindings'],
  locale: Awaited<ReturnType<typeof resolveLocale>>,
  args: MintArgs,
) {
  if (!env.OPENAI_API_KEY) {
    return jsonError(
      503,
      'upstream_unavailable',
      t('voice.upstream_failed', locale),
    );
  }
  // OpenAI Realtime GA endpoint. Returns a short-lived (~60s) client_secret
  // the iOS WebRTC layer carries as Bearer when it does the SDP exchange
  // against api.openai.com/v1/realtime/calls. We never see the audio.
  //
  // POST /v1/realtime/client_secrets — GA mint endpoint per
  // https://developers.openai.com/api/docs/guides/realtime-webrtc.
  //
  // The session config sent here is baked into the session OpenAI
  // returns the ephemeral key for; the iOS WebRTC client does not
  // need (and cannot do) a session.update for instructions later.
  // session.voice is locked once the model has emitted audio, so
  // we set it once here and never touch it again on this session.
  //
  // turn_detection defaults to semantic_vad (server-side VAD that
  // automatically truncates unplayed bot audio when the user speaks
  // mid-response — WebRTC handles the truncation transparently, no
  // client-side response.cancel needed). Leaving it unset keeps the
  // default; explicit-null disables VAD for push-to-talk only.
  //
  // audio.input.format / audio.output.format are WebSocket-only —
  // WebRTC negotiates Opus via the SDP, so we don't set them.
  let upstream: Response;
  try {
    upstream = await fetch('https://api.openai.com/v1/realtime/client_secrets', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        session: {
          type: 'realtime',
          model: args.modelOverride ?? args.route.modelToCall,
          instructions: args.instructions,
          output_modalities: ['audio'],
          // No input transcription — we don't surface a live transcript.
          // The closing recap (POST /v1/realtime/summary) is generated by
          // the realtime model itself from its own audio context.
          audio: {
            output: { voice: 'marin' },
          },
        },
      }),
    });
  } catch (err) {
    console.warn('[realtime/session] openai fetch failed', err);
    return jsonError(503, 'voice_upstream_failed', t('voice.upstream_failed', locale));
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
    value?: string;          // GA response may surface the value at top level
    expires_at?: number;     // and the expires_at alongside it.
    client_secret?: { value?: string; expires_at?: number };
    session?: { id?: string; model?: string };
    model?: string;
  };
  // The GA response schema places the ephemeral key under `value` /
  // `expires_at` at the root; some deployments still nest it as
  // `client_secret.value`. Accept both shapes.
  const clientSecret = data.value ?? data.client_secret?.value;
  const expiresAt = data.expires_at ?? data.client_secret?.expires_at ?? null;
  if (!clientSecret) {
    console.warn('[realtime/session] openai response missing client_secret', data);
    return jsonError(502, 'upstream_error', t('voice.upstream_failed', locale));

  }

  // Bind session_id to (user, conversation, bot) so /usage /transcripts
  // /end can't be replayed across users or after termination. Failure
  // here is logged but non-fatal — the call still works, just without
  // server-side replay protection. recordRealtimeSession itself logs.
  await recordRealtimeSession(env, {
    session_id: args.sessionId,
    user_id: args.userId,
    conversation_id: args.conversationId,
    bot_id: args.botId,
    openai_session_id: data.session?.id ?? data.id ?? null,
  });

  return Response.json({
    session_id: args.sessionId,
    client_secret: { value: clientSecret, expires_at: expiresAt },
    model: data.session?.model ?? data.model ?? args.route.modelToCall,
    alias_id: args.route.alias?.aliasId ?? null,
    provider_id: args.route.provider.id,
    min_threshold: args.minThreshold,
    balance_credits: args.balanceCredits,
  });
}

// Local helper used inside mintOpenAISession — that function has no
// Hono Context, so we produce a raw Response that matches the shared
// jsonError envelope shape ({ error: { code, message? } }).
function jsonError(status: number, code: ApiErrorCode, message?: string) {
  return Response.json(
    { error: { code, ...(message ? { message } : {}) } },
    { status },
  );
}

// =============================================================================
// POST /v1/realtime/attach — hand the call_id to the server-side meter
// =============================================================================
//
// iOS calls this once, right after the WebRTC SDP exchange with OpenAI
// hands it a `call_id` (the Location header of POST /v1/realtime/calls).
// The worker spins up the per-session RealtimeMeterDO, which opens a
// sideband control connection to the same call and meters usage
// server-side from OpenAI's `response.done` events. There is no longer
// a client-reported /usage endpoint — usage iOS sends could be forged.

const AttachBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
  call_id: z.string().min(1),
  // The ephemeral client_secret the WebRTC call was created with — the
  // sideband WebSocket must authenticate with it (see RealtimeMeterDO).
  client_secret: z.string().min(1),
});

realtimeRoutes.post('/attach', async (c) => {
  const userId = c.var.userId!;

  let parsed: z.infer<typeof AttachBody>;
  try {
    parsed = AttachBody.parse(await c.req.json());
  } catch (err) {
    return routeJsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Same replay gate as /transcripts: the session must exist, belong to
  // the caller, and still be active. conversation_id / bot_id below come
  // from the session row, never the request body.
  const sessGate = await requireActiveSession(c.env, parsed.session_id, userId);
  if (!sessGate.ok) return c.json(sessGate.body, sessGate.status);
  if (sessGate.session.conversation_id !== parsed.conversation_id) {
    return routeJsonError(c, 403, 'session_conversation_mismatch');
  }

  const meterId = c.env.REALTIME_METER.idFromName(parsed.session_id);
  const meter = c.env.REALTIME_METER.get(meterId);
  const resp = await meter.fetch('https://meter.internal/sideband', {
    method: 'POST',
    body: JSON.stringify({
      transport: 'sideband',
      callId: parsed.call_id,
      clientSecret: parsed.client_secret,
      sessionId: parsed.session_id,
      userId,
      conversationId: parsed.conversation_id,
      botId: sessGate.session.bot_id,
      startedAt: Date.now(),
    }),
  });
  if (!resp.ok) {
    console.warn('[realtime/attach] meter start failed', resp.status);
    return routeJsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true });
});

// =============================================================================
// GET /v1/realtime/ws — WebSocket transport: relay through the meter DO
// =============================================================================
//
// For transport:'websocket' sessions. iOS opens a WebSocket here (the
// Supabase JWT rides in the Authorization header — same requireSession
// gate as every other realtime route). The worker forwards the upgrade
// to the session's RealtimeMeterDO, which bridges it to OpenAI's
// realtime WebSocket and meters every turn server-side.

realtimeRoutes.get('/ws', async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return routeJsonError(c, 400, 'invalid_body', {
      detail: 'expected a websocket upgrade',
    });
  }
  const userId = c.var.userId!;
  const sessionId = c.req.query('session_id');
  if (!sessionId) {
    return routeJsonError(c, 400, 'invalid_body', {
      detail: 'session_id query param required',
    });
  }
  const sessGate = await requireActiveSession(c.env, sessionId, userId);
  if (!sessGate.ok) return c.json(sessGate.body, sessGate.status);

  const meterId = c.env.REALTIME_METER.idFromName(sessionId);
  return c.env.REALTIME_METER.get(meterId).fetch(c.req.raw);
});

// =============================================================================
// POST /v1/realtime/summary — store the model's closing recap of the call
// =============================================================================
//
// At hang-up the iOS client asks the realtime model for a short text recap
// of the call and posts it here. We write it as a single `messages` row
// tagged metadata.source='voice_call_summary'. The row is deliberately
// memory-only: iOS skips rendering rows with that source, but the normal
// memory pipeline (Honcho refresh, chat-memo, bot-note) reads it like any
// other bot message — so the bot keeps an impression of the call without a
// transcript ever surfacing in the timeline.

const SummaryBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
  summary: z.string().min(1).max(4000),
});

realtimeRoutes.post('/summary', async (c) => {
  const userId = c.var.userId!;

  let parsed: z.infer<typeof SummaryBody>;
  try {
    parsed = SummaryBody.parse(await c.req.json());
  } catch (err) {
    return routeJsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Same replay gate as /attach — the session must exist, belong to the
  // caller, and still be active. bot_id below comes from the session row.
  const sessGate = await requireActiveSession(c.env, parsed.session_id, userId);
  if (!sessGate.ok) return c.json(sessGate.body, sessGate.status);
  if (sessGate.session.conversation_id !== parsed.conversation_id) {
    return routeJsonError(c, 403, 'session_conversation_mismatch');
  }
  const session = sessGate.session;

  const supaService = serviceClient(c.env);
  const { error } = await supaService.from('messages').insert({
    conversation_id: parsed.conversation_id,
    client_message_id: crypto.randomUUID(),
    role: 'bot',
    status: 'done',
    content: parsed.summary.trim(),
    sender_bot_id: session.bot_id,
    metadata: {
      source: 'voice_call_summary',
      session_id: parsed.session_id,
    },
  });
  if (error) {
    console.warn('[realtime/summary] insert failed', error.message);
    return routeJsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ ok: true });
});

// =============================================================================
// POST /v1/realtime/end — session terminator
// =============================================================================
//
// No-op: client disconnect ends the OpenAI WebRTC session, and the
// ephemeral key has already expired (~60s TTL) by the time iOS calls
// this. Kept as a uniform tail-call from the iOS client and a future
// extension point for any per-session cleanup we may want to add.
const EndBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
});

realtimeRoutes.post('/end', async (c) => {
  const userId = c.var.userId!;

  let parsed: z.infer<typeof EndBody>;
  try {
    parsed = EndBody.parse(await c.req.json());
  } catch (err) {
    return routeJsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Idempotent — calling /end twice or for an already-aged-out session
  // returns ok. We only reject when the session doesn't exist at all
  // or belongs to another caller (don't help an attacker confirm
  // someone else's session_id).
  const sessGate = await requireActiveSession(c.env, parsed.session_id, userId);
  if (!sessGate.ok && sessGate.status === 403) {
    return c.json(sessGate.body, sessGate.status);
  }
  if (sessGate.ok && sessGate.session.conversation_id !== parsed.conversation_id) {
    return routeJsonError(c, 403, 'session_conversation_mismatch');
  }
  // Stop the server-side meter: close its sideband socket and finalize.
  // No-op if no meter was ever attached for this session.
  try {
    const meterId = c.env.REALTIME_METER.idFromName(parsed.session_id);
    await c.env.REALTIME_METER.get(meterId).fetch(
      'https://meter.internal/stop',
      { method: 'POST' },
    );
  } catch (err) {
    console.warn('[realtime/end] meter stop failed', err);
  }
  await endRealtimeSession(c.env, parsed.session_id);
  return c.json({ ok: true });
});
