// Group-voice control surface — the authenticated, user-facing side of
// the group-voice bridge. Mounted at /v1/groups alongside groupRoutes:
//
//   POST /v1/groups/:id/voice/start            bring the room's bots online
//   POST /v1/groups/:id/voice/add-bot          add one more bot mid-call
//   POST /v1/groups/:id/voice/join             a human joins the SFU room
//   POST /v1/groups/:id/voice/subscribe        pull bot tracks to hear them
//   POST /v1/groups/:id/voice/renegotiate      answer the SFU's offer
//   GET  /v1/groups/:id/voice/roster           current bot roster (re-sync)
//   POST /v1/groups/:id/voice/kick             remove a bot or human
//   POST /v1/groups/:id/voice/designate-admin  grant call-admin powers
//   POST /v1/groups/:id/voice/leave            the caller leaves the call
//   POST /v1/groups/:id/voice/end              tear the whole call down
//
// Each endpoint requires a Supabase JWT and re-proves the caller is a
// participant of the group. The handlers assemble each bot's persona
// server-side (it never reaches a client) and forward a control message
// to the room's RoomVoiceDO, which owns the SFU<->OpenAI audio bridge.
//
// kick / designate-admin / end are privileged: the RoomVoiceDO holds the
// initiator / group-admin / call-admin sets and is the single authority
// on who may do what — these handlers just forward the caller's id.
//
// Humans join the SFU separately (the SFU SDP proxy + /control/add-human
// path) — that is coupled to the iOS WebRTC client and lives elsewhere.

import { Hono } from 'hono';
import type { Context } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { buildSystemPrompt } from '../llm/builder';
import { getBotMemory } from '../lib/memory';
import { resolveLocale } from '../i18n/locale';
import { jsonError } from '../lib/http-error';
import { UUID_RE } from '../lib/ids';
import {
  createSfuSession,
  newSfuTracks,
  renegotiateSfuSession,
  type SfuApp,
} from '../lib/sfu';
import type { AppBindings } from '../types';

export const groupVoiceRoutes = new Hono<AppBindings>();
groupVoiceRoutes.use('*', requireSession());

// Default realtime model / voice when a bot's config doesn't pin one.
const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';
const DEFAULT_VOICE = 'marin';

// Path the SFU adapter WebSocket route is mounted on (see index.ts).
const ADAPTER_PATH = '/v1/realtime-sfu';

interface BotSpec {
  botId: string;
  model: string;
  instructions: string;
  voice: string;
}

// Pull a non-empty string field out of a bot's free-form `config` JSON.
function configString(config: unknown, key: string): string | null {
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    return null;
  }
  const v = (config as Record<string, unknown>)[key];
  return typeof v === 'string' && v.length > 0 ? v : null;
}

// A group conversation the caller is a confirmed participant of.
interface GroupContext {
  conversationId: string;
  // Group creator — voice tokens bill to this user, matching how group
  // text turns attribute cost today. M6's splitAndDebit replaces it.
  billUserId: string;
  locale: Awaited<ReturnType<typeof resolveLocale>>;
}

// Resolve + authorize: the id must be a group conversation and the caller
// must be one of its participants. Returns an HTTP-shaped error otherwise.
async function loadGroupContext(
  c: Context<AppBindings>,
): Promise<{ ok: true; ctx: GroupContext } | { ok: false; res: Response }> {
  const conversationId = c.req.param('id') ?? '';
  if (!UUID_RE.test(conversationId)) {
    return { ok: false, res: jsonError(c, 400, 'invalid_id') };
  }
  const userId = c.var.userId!;
  const supaUser = userClient(c.env, c.var.userJwt!);
  const locale = await resolveLocale(c.req.raw, supaUser, userId);

  const { data: conv } = await supaUser
    .from('conversations')
    .select('id, conversation_type, user_id')
    .eq('id', conversationId)
    .maybeSingle();
  if (!conv || conv.conversation_type !== 'group') {
    return { ok: false, res: jsonError(c, 404, 'conversation_not_found') };
  }

  const supaSvc = serviceClient(c.env);
  const { data: membership } = await supaSvc
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .eq('participant_id', userId)
    .maybeSingle();
  if (!membership) {
    return { ok: false, res: jsonError(c, 403, 'not_a_participant') };
  }

  // Group creator owns the cost. Prefer conversation_group_meta.created_by,
  // fall back to conversations.user_id when the meta row predates that col.
  const { data: meta } = await supaSvc
    .from('conversation_group_meta')
    .select('created_by')
    .eq('conversation_id', conversationId)
    .maybeSingle();
  const billUserId = meta?.created_by ?? conv.user_id ?? userId;

  return { ok: true, ctx: { conversationId, billUserId, locale } };
}

// Build a BotSpec for one bot: assemble its persona server-side and pick
// the realtime model / voice from its config. Returns null when the bot
// doesn't exist or has voice calling disabled.
async function buildBotSpec(
  c: Context<AppBindings>,
  botId: string,
  locale: Awaited<ReturnType<typeof resolveLocale>>,
): Promise<BotSpec | null> {
  const supaSvc = serviceClient(c.env);
  const { data: bot } = await supaSvc
    .from('bots')
    .select('id, output_mode, voice_call_enabled, config')
    .eq('id', botId)
    .maybeSingle();
  if (!bot || !bot.voice_call_enabled) return null;

  const botMemory = await getBotMemory(c.env, bot.id);
  // Group-voice personas use the bot's core self only. Per-user context
  // (skills, chat-memo) doesn't apply in a multi-user room; group-specific
  // prompt engineering (nicknames, per-group descriptions) lands with the
  // wider group-prompt work, same as group text turns today.
  const instructions = await buildSystemPrompt(
    supaSvc,
    {
      bot: {
        id: bot.id,
        output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
      },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
    },
    locale,
  );

  return {
    botId: bot.id,
    model: configString(bot.config, 'voiceModel') ?? DEFAULT_VOICE_MODEL_SLUG,
    instructions,
    voice: configString(bot.config, 'voice') ?? DEFAULT_VOICE,
  };
}

// The room DO is keyed by conversation_id; one control message per call.
function roomStub(c: Context<AppBindings>, conversationId: string) {
  return c.env.ROOM_VOICE.get(c.env.ROOM_VOICE.idFromName(conversationId));
}

// SFU app credentials for the WebRTC session/track negotiation.
function sfuApp(c: Context<AppBindings>): SfuApp {
  return {
    appId: c.env.SFU_APP_ID ?? '',
    appSecret: c.env.SFU_APP_SECRET ?? '',
  };
}

async function controlRoom(
  c: Context<AppBindings>,
  conversationId: string,
  path: string,
  body: unknown,
): Promise<Response> {
  return roomStub(c, conversationId).fetch(`https://room-voice.internal${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

// =============================================================================
// POST /:id/voice/start
// =============================================================================

const StartBody = z.object({
  // Which group bots to bring into the call. Omitted = every bot that is
  // a participant of the group.
  bot_ids: z.array(z.string().uuid()).optional(),
});

groupVoiceRoutes.post('/:id/voice/start', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId, billUserId, locale } = loaded.ctx;

  let parsed: z.infer<typeof StartBody>;
  try {
    parsed = StartBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // The group's bot participants. A start request may pick a subset.
  const supaSvc = serviceClient(c.env);
  const { data: botParts } = await supaSvc
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'bot');
  const groupBotIds = new Set((botParts ?? []).map((r) => r.participant_id as string));
  const wanted = parsed.bot_ids
    ? parsed.bot_ids.filter((id) => groupBotIds.has(id))
    : [...groupBotIds];
  if (wanted.length === 0) {
    return jsonError(c, 400, 'voice_bot_disabled', {
      detail: 'no group bots selected',
    });
  }

  // Assemble each bot's leg spec. Bots with voice calling disabled drop out.
  const specs: BotSpec[] = [];
  for (const botId of wanted) {
    const spec = await buildBotSpec(c, botId, locale);
    if (spec) specs.push(spec);
  }
  if (specs.length === 0) {
    return jsonError(c, 403, 'voice_bot_disabled', {
      detail: 'no voice-enabled bots in this group',
    });
  }

  // Group owner + admins are privileged for the whole call. The caller
  // (initiator) is privileged too — passed separately below.
  const { data: adminRows } = await supaSvc
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .in('role', ['owner', 'admin']);
  const groupAdminIds = (adminRows ?? []).map((r) => r.participant_id as string);

  // wss:// origin the SFU dials back to reach this worker.
  const wsBase = `wss://${new URL(c.req.url).host}`;
  const payload = {
    room: {
      roomId: conversationId,
      conversationId,
      billUserId,
      initiatorUserId: c.var.userId!,
      groupAdminIds,
      publicWsBase: wsBase,
      adapterPath: ADAPTER_PATH,
      adapterToken: crypto.randomUUID(),
    },
    bots: specs,
  };

  const resp = await controlRoom(c, conversationId, '/control/start', payload);
  if (!resp.ok) {
    console.warn('[group-voice/start] room DO start failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  // The DO answers `{ already: true }` when the room was already up — so
  // `initiated` tells this caller whether *they* opened the call (and are
  // therefore privileged for its lifetime).
  const startData = (await resp.json().catch(() => ({}))) as { already?: boolean };
  return c.json({
    ok: true,
    room_id: conversationId,
    bot_ids: specs.map((s) => s.botId),
    initiated: !startData.already,
  });
});

// =============================================================================
// POST /:id/voice/add-bot
// =============================================================================

const BotIdBody = z.object({ bot_id: z.string().uuid() });

groupVoiceRoutes.post('/:id/voice/add-bot', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId, locale } = loaded.ctx;

  let parsed: z.infer<typeof BotIdBody>;
  try {
    parsed = BotIdBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // The bot must actually be a participant of this group.
  const supaSvc = serviceClient(c.env);
  const { data: part } = await supaSvc
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'bot')
    .eq('participant_id', parsed.bot_id)
    .maybeSingle();
  if (!part) return jsonError(c, 404, 'not_found', { detail: 'bot not in group' });

  const spec = await buildBotSpec(c, parsed.bot_id, locale);
  if (!spec) return jsonError(c, 403, 'voice_bot_disabled');

  const resp = await controlRoom(c, conversationId, '/control/add-bot', spec);
  if (!resp.ok) {
    console.warn('[group-voice/add-bot] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true, bot_id: parsed.bot_id });
});

// =============================================================================
// POST /:id/voice/kick — remove a bot or a human from the call
// =============================================================================
//
// Privileged actors only. The RoomVoiceDO owns the privilege decision
// (it holds the initiator / group-admin / call-admin sets) and refuses a
// kick that would strand the room without a human admin.

const KickBody = z.object({
  target_type: z.enum(['bot', 'human']),
  target_id: z.string().uuid(),
});

groupVoiceRoutes.post('/:id/voice/kick', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  let parsed: z.infer<typeof KickBody>;
  try {
    parsed = KickBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const resp = await controlRoom(c, conversationId, '/control/kick', {
    actorId: c.var.userId!,
    targetType: parsed.target_type,
    targetId: parsed.target_id,
  });
  if (resp.status === 403) return jsonError(c, 403, 'forbidden');
  if (resp.status === 409) {
    return jsonError(c, 409, 'conflict', {
      detail: 'would leave the room without a human admin',
    });
  }
  if (!resp.ok) {
    console.warn('[group-voice/kick] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true });
});

// =============================================================================
// POST /:id/voice/designate-admin — grant call-admin powers
// =============================================================================
//
// Privileged actors only. The target may be a human user or a bot.

groupVoiceRoutes.post('/:id/voice/designate-admin', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  let parsed: { target_id: string };
  try {
    parsed = z.object({ target_id: z.string().uuid() }).parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const resp = await controlRoom(c, conversationId, '/control/designate-admin', {
    actorId: c.var.userId!,
    targetId: parsed.target_id,
  });
  if (resp.status === 403) return jsonError(c, 403, 'forbidden');
  if (!resp.ok) {
    console.warn('[group-voice/designate-admin] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true });
});

// =============================================================================
// POST /:id/voice/leave — the caller leaves the call
// =============================================================================
//
// Any participant may leave. If the caller is the last human admin, the
// call ends (the RoomVoiceDO's human-admin invariant) unless they first
// designated a successor via /designate-admin.

groupVoiceRoutes.post('/:id/voice/leave', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const resp = await controlRoom(c, conversationId, '/control/leave', {
    humanId: c.var.userId!,
  });
  if (!resp.ok) {
    console.warn('[group-voice/leave] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true });
});

// =============================================================================
// POST /:id/voice/end — end the whole call
// =============================================================================
//
// Privileged actors only — the DO checks and returns 403 otherwise.

groupVoiceRoutes.post('/:id/voice/end', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const resp = await controlRoom(c, conversationId, '/control/end', {
    actorId: c.var.userId!,
  });
  if (resp.status === 403) return jsonError(c, 403, 'forbidden');
  if (!resp.ok) {
    console.warn('[group-voice/end] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true });
});

// =============================================================================
// POST /:id/voice/join — a human joins the call's SFU room
// =============================================================================
//
// The worker is the "Backend Server" of the SFU lifecycle: it negotiates
// the human's RTCPeerConnection against the SFU on iOS's behalf.
//
//   iOS posts its WebRTC offer →
//     1. createSfuSession()                — the human's SFU session
//     2. newSfuTracks(offer, autoDiscover) — publish the human's mic;
//        the SFU answers and echoes back the discovered track name
//     3. RoomVoiceDO /control/add-human    — the DO streams that track
//        into the bot mix and returns the current bot roster
//   ← worker returns the SFU answer + the bot roster
//
// iOS then calls /subscribe to pull the bot tracks and hear them.

const JoinBody = z.object({ sdp: z.string().min(1) });

groupVoiceRoutes.post('/:id/voice/join', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  let parsed: z.infer<typeof JoinBody>;
  try {
    parsed = JoinBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const app = sfuApp(c);
  let humanSessionId: string;
  let answerSdp: string;
  let humanTrackName: string;
  try {
    humanSessionId = await createSfuSession(app);
    const res = await newSfuTracks(app, humanSessionId, {
      sessionDescription: { type: 'offer', sdp: parsed.sdp },
      tracks: [],
      autoDiscover: true,
    });
    answerSdp = res.sessionDescription?.sdp ?? '';
    humanTrackName = res.tracks[0]?.trackName ?? '';
  } catch (err) {
    console.warn('[group-voice/join] SFU negotiation failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
  if (!answerSdp || !humanTrackName) {
    return jsonError(c, 502, 'voice_upstream_failed', {
      detail: 'SFU returned no answer or track',
    });
  }

  const doResp = await controlRoom(c, conversationId, '/control/add-human', {
    humanId: c.var.userId!,
    sfuSessionId: humanSessionId,
    sfuTrackName: humanTrackName,
  });
  if (!doResp.ok) {
    // The DO returns 400 when the room hasn't been started yet.
    if (doResp.status === 400) {
      return jsonError(c, 409, 'conflict', { detail: 'voice room not started' });
    }
    console.warn('[group-voice/join] room DO add-human failed', doResp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  const roster = (await doResp.json()) as { bots?: unknown; humans?: unknown };

  return c.json({
    ok: true,
    session_id: humanSessionId,
    answer: answerSdp,
    bots: roster.bots ?? [],
    humans: roster.humans ?? [],
  });
});

// =============================================================================
// POST /:id/voice/subscribe — pull bot tracks so the human can hear them
// =============================================================================
//
// Adds remote tracks to the caller's SFU session. The SFU replies with an
// offer (requires_renegotiation); iOS answers it via /renegotiate.

const SubscribeBody = z.object({
  session_id: z.string().min(1),
  tracks: z
    .array(z.object({ session_id: z.string().min(1), track_name: z.string().min(1) }))
    .min(1),
});

groupVoiceRoutes.post('/:id/voice/subscribe', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;

  let parsed: z.infer<typeof SubscribeBody>;
  try {
    parsed = SubscribeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  let res;
  try {
    res = await newSfuTracks(sfuApp(c), parsed.session_id, {
      tracks: parsed.tracks.map((t) => ({
        location: 'remote' as const,
        sessionId: t.session_id,
        trackName: t.track_name,
      })),
    });
  } catch (err) {
    console.warn('[group-voice/subscribe] SFU tracks/new failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
  return c.json({
    ok: true,
    offer: res.sessionDescription?.sdp ?? null,
    requires_renegotiation: res.requiresImmediateRenegotiation ?? false,
    tracks: res.tracks,
  });
});

// =============================================================================
// GET /:id/voice/roster — current bot roster, for mid-call re-sync
// =============================================================================
//
// /join hands back the roster at join time; this lets a client that
// added a bot mid-call (or wants to recover) pull the current set of
// bots — each with the SFU session + track a human subscribes to.

groupVoiceRoutes.get('/:id/voice/roster', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const resp = await controlRoom(c, conversationId, '/control/roster', {});
  if (!resp.ok) {
    console.warn('[group-voice/roster] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  const roster = (await resp.json()) as { bots?: unknown; humans?: unknown };
  return c.json({
    ok: true,
    bots: roster.bots ?? [],
    humans: roster.humans ?? [],
  });
});

// =============================================================================
// POST /:id/voice/renegotiate — answer the SFU's renegotiation offer
// =============================================================================

const RenegotiateBody = z.object({
  session_id: z.string().min(1),
  sdp: z.string().min(1),
});

groupVoiceRoutes.post('/:id/voice/renegotiate', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;

  let parsed: z.infer<typeof RenegotiateBody>;
  try {
    parsed = RenegotiateBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  try {
    await renegotiateSfuSession(sfuApp(c), parsed.session_id, {
      type: 'answer',
      sdp: parsed.sdp,
    });
  } catch (err) {
    console.warn('[group-voice/renegotiate] SFU renegotiate failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
  return c.json({ ok: true });
});
