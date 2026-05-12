// Voice call HTTP surface (M5+). One provider — OpenAI Realtime.
//
//   POST /v1/realtime/session      — mint ephemeral client_secret + bake
//                                    bot system prompt server-side
//   POST /v1/realtime/usage        — per-turn audit + debit + balance gate
//   POST /v1/realtime/transcripts  — write turn rows to messages
//   POST /v1/realtime/end          — close session (no-op, kept as a
//                                    uniform tail-call for the iOS client
//                                    and an extension point for future
//                                    cleanup hooks)
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
import { resolveRoute, recordAudit } from '../llm/router';
import { buildSystemPrompt, type BuildSystemPromptInput } from '../llm/builder';
import { getBotMemory, getChatMemo } from '../lib/memory';
import { resolveLocale } from '../i18n/locale';
import { t } from '../i18n/index';
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

// Canonical model slug. task_routing_rules lookup is keyed off this in
// resolveRoute(..., taskType: 'voice_call') so admins can override per
// task/user without touching the route handler.
const OPENAI_MODEL_SLUG = 'gpt-realtime';

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
    .select('id, display_name, output_mode, voice_call_enabled')
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
        output_mode: bot.output_mode,
        voice_call_enabled: true,
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

  // Region gate. cf.country is what Cloudflare's edge GeoIP reports for
  // the request's egress IP; blocked list lives in lib/openai-regions.ts.
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

  // Persona assembled server-side. Goes into the upstream mint body —
  // never touches the iOS device.
  const instructions = await assembleInstructions(c.env, ctx);

  // Route resolution. task_routing_rules can still override at admin
  // discretion via taskType='voice_call'.
  let route;
  try {
    route = await resolveRoute(supaUser, c.env, {
      modelSlug: OPENAI_MODEL_SLUG,
      taskType: 'voice_call',
    });
  } catch (err) {
    console.warn('[realtime/session] resolveRoute failed', err);
    return c.json(
      { error: { code: 'voice_upstream_failed', message: t('voice.upstream_failed', locale) } },
      503,
    );
  }

  const sessionId = crypto.randomUUID();
  return await mintOpenAISession(c.env, locale, {
    sessionId,
    userId,
    conversationId: parsed.conversation_id,
    botId: ctx.bot.id,
    route,
    instructions,
    balanceCredits,
    minThreshold,
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
          model: args.route.modelToCall,
          instructions: args.instructions,
          output_modalities: ['audio'],
          audio: {
            output: { voice: 'marin' },
            // Streaming user-side transcription. The
            // conversation.item.input_audio_transcription.completed
            // event then carries the final text iOS buffers for the
            // post-call /transcripts upload. whisper-1 is the more
            // stable in-session option vs the newer gpt-realtime-
            // whisper which is still showing intermittent
            // reliability gaps inside Realtime sessions per the
            // 2025-11 community thread; revisit once that settles.
            input: { transcription: { model: 'whisper-1' } },
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
// POST /v1/realtime/usage — per-turn audit + debit + balance gate
// =============================================================================

const UsageBody = z.object({
  session_id: z.string(),
  conversation_id: z.string(),
  alias_id: z.string().nullable().optional(),
  provider_id: z.string(),
  // Per-turn deltas pulled from response.done.usage on the iOS side.
  // cached_input_tokens is a subset of audio_input_tokens + text_input_tokens
  // (cached portion already counted in those), discounted via the alias
  // cached_input_price (GA cached-audio rate is ~80× cheaper than full).
  audio_input_tokens: z.number().int().min(0).optional(),
  audio_output_tokens: z.number().int().min(0).optional(),
  text_input_tokens: z.number().int().min(0).optional(),
  text_output_tokens: z.number().int().min(0).optional(),
  cached_input_tokens: z.number().int().min(0).optional(),
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
    return routeJsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Replay protection. The session_id MUST map to a row in
  // realtime_sessions, owned by the caller, not closed, not aged out.
  // We then trust the conversation_id from that row, not from the
  // request body — guards against a caller forging a body that names
  // a different conversation than the session was minted for.
  const sessGate = await requireActiveSession(c.env, parsed.session_id, userId);
  if (!sessGate.ok) return c.json(sessGate.body, sessGate.status);
  if (sessGate.session.conversation_id !== parsed.conversation_id) {
    return routeJsonError(c, 403, 'session_conversation_mismatch');
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
  // have tweaked audio_*_price between session start and this tick. The
  // mid-call price edit takes effect on the next turn, which is the
  // propagation window admins expect from the board.
  let route;
  try {
    route = await resolveRoute(supaUser, c.env, {
      modelSlug: OPENAI_MODEL_SLUG,
      taskType: 'voice_call',
      preferProvider: 'openai',
    });
  } catch (err) {
    console.warn('[realtime/usage] resolveRoute failed', err);
    return routeJsonError(c, 503, 'upstream_unavailable');
  }

  const startedAt = Date.now();
  // recordAudit's computeCost pricing model:
  //   audio_in  cost  = audio_input_tokens  × alias.audio_input_price /1M
  //   audio_out cost  = audio_output_tokens × alias.audio_output_price /1M
  //   text_in   cost  = text_input_tokens   × alias.input_price        /1M
  //   text_out  cost  = text_output_tokens  × alias.output_price       /1M
  //   cached_in cost  = cache_read_tokens   × alias.cached_input_price /1M
  // The cached_input_tokens forwarded from iOS is a SUBSET of the audio
  // and text input tokens above — recordAudit ends up double-counting
  // them (full price + cached price), which is exactly wrong: it
  // OVERcharges. Per the GA pricing model, cached tokens replace the
  // full-rate input charge for that portion. We compensate by
  // subtracting cached_input_tokens from audio_input_tokens before
  // passing it to recordAudit (assume cached tokens are predominantly
  // audio in a voice call — the text-instruction cache is tiny).
  const audioIn = Math.max(
    0,
    (parsed.audio_input_tokens ?? 0) - (parsed.cached_input_tokens ?? 0),
  );
  await recordAudit(supaUser, route, {
    userId,
    conversationId: parsed.conversation_id,
    taskType: 'voice_call',
    startedAt,
    status: 'success',
    inputTokens: parsed.text_input_tokens ?? 0,
    outputTokens: parsed.text_output_tokens ?? 0,
    audioInputTokens: audioIn,
    audioOutputTokens: parsed.audio_output_tokens ?? 0,
    cacheReadTokens: parsed.cached_input_tokens ?? 0,
    metadata: {
      source: 'voice_call',
      session_id: parsed.session_id,
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
  // Approximate turn cost as the most recent row's cost — we don't ledger
  // by-turn separately. Falls back to 0 on an alias without audio pricing.
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
    return routeJsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Same gate as /usage — every persistence call must be on a still-
  // active session owned by the caller. user_id and bot_id used in the
  // rows below come from the session row, not the request body.
  const sessGate = await requireActiveSession(c.env, parsed.session_id, userId);
  if (!sessGate.ok) return c.json(sessGate.body, sessGate.status);
  if (sessGate.session.conversation_id !== parsed.conversation_id) {
    return routeJsonError(c, 403, 'session_conversation_mismatch');
  }
  const session = sessGate.session;

  const loaded = await loadSessionContext(
    c.env,
    userId,
    userJwt,
    parsed.conversation_id,
    locale,
  );
  if (!loaded.ok) return c.json(loaded.body, loaded.status);
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
    user_id: t.role === 'user' ? session.user_id : null,
    sender_bot_id: t.role === 'bot' ? session.bot_id : null,
    metadata: {
      source: 'voice_call',
      session_id: parsed.session_id,
      turn_index: idx,
      ts: t.ts,
    },
  }));
  const { error } = await supaService
    .from('messages')
    .insert(rows);
  if (error) {
    console.warn('[realtime/transcripts] insert failed', error.message);
    return routeJsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ inserted: rows.length });
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
  await endRealtimeSession(c.env, parsed.session_id);
  return c.json({ ok: true });
});
