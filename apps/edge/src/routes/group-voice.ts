// Group-voice control surface — the authenticated, user-facing side of
// the group-voice bridge. Mounted at /v1/groups alongside groupRoutes:
//
//   POST /v1/groups/:id/voice/start            open the (empty) call
//   POST /v1/groups/:id/voice/add-bot          add a bot to the call
//   POST /v1/groups/:id/voice/ring             ring a human into the call
//   POST /v1/groups/:id/voice/cancel-invite    drop a pending invite
//   POST /v1/groups/:id/voice/realtimekit/bootstrap
//                                                 mint RealtimeKit tokens
//   POST /v1/groups/:id/voice/realtimekit/leave caller leaves RealtimeKit
//   POST /v1/groups/:id/voice/realtimekit/end   end RealtimeKit for everyone
//   POST /v1/groups/:id/voice/join             a human joins the SFU room
//   POST /v1/groups/:id/voice/subscribe        pull bot tracks to hear them
//   POST /v1/groups/:id/voice/renegotiate      answer the SFU's offer
//   GET  /v1/groups/:id/voice/roster           current roster (re-sync)
//   POST /v1/groups/:id/voice/kick             remove a bot or human
//   POST /v1/groups/:id/voice/designate-admin  grant call-admin powers
//   POST /v1/groups/:id/voice/leave            the caller leaves the call
//   POST /v1/groups/:id/voice/heartbeat        iOS keepalive; absence == gone
//   POST /v1/groups/:id/voice/end              tear the whole call down
//
// /start opens an empty room — bots are NOT auto-pulled, and humans are
// NOT auto-rung. The caller alone is in the room until they tap "叫
// 机器人来" (/add-bot) or "叫真人来" (/ring) inside the call UI.
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
import { sendVoipRing } from '../lib/push';
import { generateTurnCredentials } from '../lib/cf-turn';
import {
  createSfuSession,
  newSfuTracks,
  renegotiateSfuSession,
  type SfuApp,
} from '../lib/sfu';
import {
  addRealtimeKitParticipant,
  bootstrapRealtimeKitGroupVoice,
  kickAllRealtimeKitParticipants,
  realtimeKitAppFromEnv,
} from '../lib/realtimekit';
import {
  addRealtimeKitBot,
  addRealtimeKitHuman,
  recordRealtimeKitEnded,
  recordRealtimeKitState,
  removeRealtimeKitBot,
  removeRealtimeKitHuman,
  type RealtimeKitRoomState,
} from '../lib/realtimekit-lifecycle';
import {
  resolveVoiceConfig,
  type ResolvedVoiceConfig,
} from '../lib/voice-config';
import type { AppBindings } from '../types';

export const groupVoiceRoutes = new Hono<AppBindings>();
groupVoiceRoutes.use('*', requireSession());

// Default realtime model when a bot's config doesn't pin one. (Voice id +
// turn-detection defaults live in lib/voice-config.)
const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';

// Path the SFU adapter WebSocket route is mounted on (see index.ts).
const ADAPTER_PATH = '/v1/realtime-sfu';
const DEFAULT_REALTIMEKIT_HUMAN_PRESET = 'group_call_host';
const DEFAULT_REALTIMEKIT_BOT_PRESET = 'group_call_participant';
const REALTIMEKIT_MEETING_TTL_SECONDS = 2 * 60 * 60;

interface BotSpec {
  botId: string;
  model: string;
  instructions: string;
  voiceConfig: ResolvedVoiceConfig;
  realtimeKit?: {
    meetingId: string;
    participantId: string;
    authToken: string;
  };
}

interface RealtimeKitCachedMeeting {
  id: string;
  title?: string | null;
  startedAt?: number;
  initiatorId?: string;
  humanIds?: string[];
  botIds?: string[];
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
    .select('id, display_name, output_mode, voice_call_enabled, config, tz')
    .eq('id', botId)
    .maybeSingle();
  if (!bot || !bot.voice_call_enabled) return null;

  const botMemory = await getBotMemory(c.env, bot.id);
  // Group-voice personas use the bot's core self only. Per-user context
  // (skills, chat-memo) doesn't apply in a multi-user room. The platform
  // layer comes from the dedicated `group-voice` prompt (spoken style +
  // turn-taking) via surface 'group-voice' below. Per-group prompt knobs
  // (nicknames, per-group descriptions) still land with the wider work.
  const instructions = await buildSystemPrompt(
    supaSvc,
    {
      bot: {
        id: bot.id,
        display_name: (bot.display_name as string | null) ?? '',
        output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
        tz: (bot.tz as string | null) ?? null,
      },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
    },
    locale,
    'group-voice',
  );

  return {
    botId: bot.id,
    model: configString(bot.config, 'voiceModel') ?? DEFAULT_VOICE_MODEL_SLUG,
    instructions,
    voiceConfig: resolveVoiceConfig(bot.config),
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

function realtimeKitMeetingKey(conversationId: string): string {
  return `group-voice:realtimekit:${conversationId}`;
}

async function loadGroupAdminIds(
  c: Context<AppBindings>,
  conversationId: string,
): Promise<string[]> {
  const { data: adminRows } = await serviceClient(c.env)
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .in('role', ['owner', 'admin']);
  return (adminRows ?? []).map((r) => r.participant_id as string);
}

async function putRealtimeKitRoomState(
  c: Context<AppBindings>,
  conversationId: string,
  state: RealtimeKitRoomState,
): Promise<void> {
  await c.env.MEMORY.put(
    realtimeKitMeetingKey(conversationId),
    JSON.stringify(state),
    { expirationTtl: REALTIMEKIT_MEETING_TTL_SECONDS },
  );
}

async function isRealtimeKitEndAllowed(
  c: Context<AppBindings>,
  conversationId: string,
  state: RealtimeKitRoomState,
): Promise<boolean> {
  const userId = c.var.userId!;
  if (state.initiatorId === userId) return true;

  const { data: membership } = await serviceClient(c.env)
    .from('conversation_participants')
    .select('role')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .eq('participant_id', userId)
    .maybeSingle();
  return membership?.role === 'owner' || membership?.role === 'admin';
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

async function startRealtimeKitRoomControl(
  c: Context<AppBindings>,
  loaded: GroupContext,
  state: RealtimeKitRoomState,
  bots: BotSpec[],
): Promise<Response> {
  return controlRoom(c, loaded.conversationId, '/control/realtimekit/start', {
    room: {
      mediaProvider: 'realtimekit',
      roomId: loaded.conversationId,
      conversationId: loaded.conversationId,
      billUserId: loaded.billUserId,
      initiatorUserId: state.initiatorId,
      groupAdminIds: await loadGroupAdminIds(c, loaded.conversationId),
      mediaToken: crypto.randomUUID(),
      realtimeKitMeetingId: state.id,
      realtimeKitHumanIds: state.humanIds,
    },
    bots,
  });
}

async function syncRealtimeKitRoomHumans(
  c: Context<AppBindings>,
  conversationId: string,
  state: RealtimeKitRoomState,
): Promise<void> {
  const resp = await controlRoom(c, conversationId, '/control/realtimekit/sync-humans', {
    humanIds: state.humanIds,
  }).catch(() => null);
  if (resp && !resp.ok && resp.status !== 400) {
    console.warn('[group-voice/realtimekit] human sync failed', resp.status);
  }
}

// =============================================================================
// POST /:id/voice/start
// =============================================================================
//
// Open the call. Empty room — no bots, no other humans rung. The caller
// follows up with /join (their own WebRTC SDP), then with /add-bot or
// /ring from inside the call UI to bring others in.

groupVoiceRoutes.post('/:id/voice/start', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId, billUserId } = loaded.ctx;

  // Group owner + admins are privileged for the whole call. The caller
  // (initiator) is privileged too — passed separately below.
  const groupAdminIds = await loadGroupAdminIds(c, conversationId);

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
    bots: [] as BotSpec[],
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

  // Mint Cloudflare TURN credentials so iOS can gather srflx + relay
  // candidates against the SFU. Without them iOS only has host
  // candidates, and any NAT between the device and the SFU prevents ICE
  // from completing — which was the visible "网络中断" symptom group
  // voice was hitting. Best-effort: a null mint just means the client
  // falls back to host-only (works on the same LAN as the SFU edge).
  const iceServers = await generateTurnCredentials(c.env);
  return c.json({
    ok: true,
    room_id: conversationId,
    initiated: !startData.already,
    ice_servers: iceServers ?? [],
  });
});

// =============================================================================
// POST /:id/voice/realtimekit/bootstrap
// =============================================================================
//
// Cloudflare RealtimeKit room layer. It creates/reuses a meeting, returns a
// participant token, and mirrors the room lifecycle into the same active-call
// index + conv-channel frames that the legacy RoomVoiceDO owns for the SFU path.

const RealtimeKitBootstrapBody = z.object({
  bot_id: z.string().uuid().optional(),
});

groupVoiceRoutes.post('/:id/voice/realtimekit/bootstrap', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  let parsed: z.infer<typeof RealtimeKitBootstrapBody>;
  try {
    parsed = RealtimeKitBootstrapBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const app = realtimeKitAppFromEnv(c.env);
  if (!app) {
    return jsonError(c, 503, 'upstream_unavailable', {
      detail: 'RealtimeKit is not configured',
    });
  }

  const supaSvc = serviceClient(c.env);
  const { data: userRow } = await supaSvc
    .from('users')
    .select('display_name')
    .eq('id', c.var.userId!)
    .maybeSingle();

  let bot:
    | {
        botId: string;
        displayName?: string | null;
        presetName: string;
      }
    | undefined;
  if (parsed.bot_id) {
    const [{ data: part }, { data: botRow }] = await Promise.all([
      supaSvc
        .from('conversation_participants')
        .select('participant_id')
        .eq('conversation_id', conversationId)
        .eq('participant_type', 'bot')
        .eq('participant_id', parsed.bot_id)
        .maybeSingle(),
      supaSvc
        .from('bots')
        .select('id, display_name, voice_call_enabled')
        .eq('id', parsed.bot_id)
        .maybeSingle(),
    ]);
    if (!part) return jsonError(c, 404, 'not_found', { detail: 'bot not in group' });
    if (!botRow || !botRow.voice_call_enabled) {
      return jsonError(c, 403, 'voice_bot_disabled');
    }
    bot = {
      botId: parsed.bot_id,
      displayName: (botRow.display_name as string | null | undefined) ?? null,
      presetName:
        c.env.REALTIMEKIT_BOT_PRESET ??
        c.env.REALTIMEKIT_HUMAN_PRESET ??
        DEFAULT_REALTIMEKIT_BOT_PRESET,
    };
  }

  try {
    const meetingKey = realtimeKitMeetingKey(conversationId);
    let meeting = await c.env.MEMORY.get<RealtimeKitCachedMeeting>(meetingKey, 'json');
    if (!meeting?.id) {
      const title = `PendingBot group voice ${conversationId}`;
      meeting = { id: '', title };
    }
    const boot = await bootstrapRealtimeKitGroupVoice(app, {
      conversationId,
      meeting: meeting.id ? meeting : undefined,
      humanUserId: c.var.userId!,
      humanDisplayName: (userRow?.display_name as string | null | undefined) ?? null,
      humanPresetName:
        c.env.REALTIMEKIT_HUMAN_PRESET ?? DEFAULT_REALTIMEKIT_HUMAN_PRESET,
      bot,
    });
    const state = addRealtimeKitHuman(
      {
        id: boot.meeting.id,
        title: boot.meeting.title ?? meeting.title ?? null,
        startedAt: meeting.startedAt,
        initiatorId: meeting.initiatorId,
        humanIds: meeting.humanIds,
        botIds: meeting.botIds,
      },
      c.var.userId!,
      Date.now(),
    );
    await putRealtimeKitRoomState(c, conversationId, state);
    await recordRealtimeKitState(c.env, conversationId, state);
    await startRealtimeKitRoomControl(c, loaded.ctx, state, []).catch((err) =>
      console.warn('[group-voice/realtimekit/bootstrap] room control sync failed', err),
    );

    return c.json({
      ok: true,
      provider: 'cloudflare_realtimekit',
      initiated: state.initiatorId === c.var.userId!,
      app_id: app.appId,
      meeting: {
        id: boot.meeting.id,
        title: boot.meeting.title ?? null,
      },
      human: {
        id: boot.human.id,
        custom_participant_id: boot.human.customParticipantId,
        display_name: boot.human.displayName ?? null,
        preset_name: boot.human.presetName,
        token: boot.human.token,
      },
      ...(boot.bot
        ? {
            bot: {
              id: boot.bot.id,
              custom_participant_id: boot.bot.customParticipantId,
              display_name: boot.bot.displayName ?? null,
              preset_name: boot.bot.presetName,
              token: boot.bot.token,
            },
          }
        : {}),
    });
  } catch (err) {
    console.warn('[group-voice/realtimekit/bootstrap] failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
});

// =============================================================================
// POST /:id/voice/realtimekit/leave — the caller leaves the RealtimeKit call
// =============================================================================

groupVoiceRoutes.post('/:id/voice/realtimekit/leave', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const meetingKey = realtimeKitMeetingKey(conversationId);
  const state = await c.env.MEMORY.get<RealtimeKitRoomState>(meetingKey, 'json');
  if (!state?.id) {
    await recordRealtimeKitEnded(c.env, conversationId);
    await controlRoom(c, conversationId, '/control/realtimekit/finalize', {}).catch(() => null);
    return c.json({ ok: true, ended: true });
  }

  const next = removeRealtimeKitHuman(state, c.var.userId!);
  if (next.humanIds.length === 0) {
    await c.env.MEMORY.delete(meetingKey);
    await recordRealtimeKitEnded(c.env, conversationId);
    await controlRoom(c, conversationId, '/control/realtimekit/finalize', {}).catch((err) =>
      console.warn('[group-voice/realtimekit/leave] room finalize failed', err),
    );
    return c.json({ ok: true, ended: true });
  }

  await putRealtimeKitRoomState(c, conversationId, next);
  await recordRealtimeKitState(c.env, conversationId, next);
  await syncRealtimeKitRoomHumans(c, conversationId, next);
  return c.json({ ok: true, ended: false });
});

// =============================================================================
// POST /:id/voice/realtimekit/end — end the RealtimeKit call for everyone
// =============================================================================

groupVoiceRoutes.post('/:id/voice/realtimekit/end', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const meetingKey = realtimeKitMeetingKey(conversationId);
  const state = await c.env.MEMORY.get<RealtimeKitRoomState>(meetingKey, 'json');
  if (!state?.id) {
    await recordRealtimeKitEnded(c.env, conversationId);
    await controlRoom(c, conversationId, '/control/realtimekit/finalize', {}).catch(() => null);
    return c.json({ ok: true, ended: true });
  }

  if (!(await isRealtimeKitEndAllowed(c, conversationId, state))) {
    return jsonError(c, 403, 'forbidden');
  }

  await c.env.MEMORY.delete(meetingKey);
  await recordRealtimeKitEnded(c.env, conversationId);
  await controlRoom(c, conversationId, '/control/realtimekit/finalize', {}).catch((err) =>
    console.warn('[group-voice/realtimekit/end] room finalize failed', err),
  );

  const app = realtimeKitAppFromEnv(c.env);
  if (app) {
    await kickAllRealtimeKitParticipants(app, state.id).catch((err) =>
      console.warn('[group-voice/realtimekit/end] kick-all failed', err),
    );
  }

  return c.json({ ok: true, ended: true });
});

// =============================================================================
// POST /:id/voice/add-bot
// =============================================================================

const BotIdBody = z.object({ bot_id: z.string().uuid() });

groupVoiceRoutes.post('/:id/voice/realtimekit/add-bot', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId, locale } = loaded.ctx;

  let parsed: z.infer<typeof BotIdBody>;
  try {
    parsed = BotIdBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const meetingKey = realtimeKitMeetingKey(conversationId);
  const state = await c.env.MEMORY.get<RealtimeKitRoomState>(meetingKey, 'json');
  if (!state?.id) {
    return jsonError(c, 409, 'conflict', { detail: 'RealtimeKit room not started' });
  }

  const app = realtimeKitAppFromEnv(c.env);
  if (!app) {
    return jsonError(c, 503, 'upstream_unavailable', {
      detail: 'RealtimeKit is not configured',
    });
  }

  const supaSvc = serviceClient(c.env);
  const [{ data: part }, { data: botRow }] = await Promise.all([
    supaSvc
      .from('conversation_participants')
      .select('participant_id')
      .eq('conversation_id', conversationId)
      .eq('participant_type', 'bot')
      .eq('participant_id', parsed.bot_id)
      .maybeSingle(),
    supaSvc
      .from('bots')
      .select('id, display_name, voice_call_enabled')
      .eq('id', parsed.bot_id)
      .maybeSingle(),
  ]);
  if (!part) return jsonError(c, 404, 'not_found', { detail: 'bot not in group' });
  if (!botRow || !botRow.voice_call_enabled) {
    return jsonError(c, 403, 'voice_bot_disabled');
  }

  const baseSpec = await buildBotSpec(c, parsed.bot_id, locale);
  if (!baseSpec) return jsonError(c, 403, 'voice_bot_disabled');

  try {
    const participant = await addRealtimeKitParticipant(app, state.id, {
      customParticipantId: `pendingbot:bot:${parsed.bot_id}:${crypto.randomUUID()}`,
      displayName: (botRow.display_name as string | null | undefined) ?? null,
      presetName:
        c.env.REALTIMEKIT_BOT_PRESET ??
        c.env.REALTIMEKIT_HUMAN_PRESET ??
        DEFAULT_REALTIMEKIT_BOT_PRESET,
    });
    const spec: BotSpec = {
      ...baseSpec,
      realtimeKit: {
        meetingId: state.id,
        participantId: participant.id,
        authToken: participant.token,
      },
    };
    const next = addRealtimeKitBot(state, parsed.bot_id);
    const roomResp = await startRealtimeKitRoomControl(c, loaded.ctx, next, [spec]);
    if (!roomResp.ok) {
      console.warn('[group-voice/realtimekit/add-bot] room DO failed', roomResp.status);
      return jsonError(c, 502, 'voice_upstream_failed');
    }

    await putRealtimeKitRoomState(c, conversationId, next);
    await recordRealtimeKitState(c.env, conversationId, next);
    return c.json({
      ok: true,
      bot_id: parsed.bot_id,
      participant_id: participant.id,
    });
  } catch (err) {
    console.warn('[group-voice/realtimekit/add-bot] failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
});

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
// POST /:id/voice/ring — ring a human into the call
// =============================================================================
//
// Adds the target user to the call's pending-invite set and sends them an
// APNs push so their phone actually rings. Any participant currently in
// the call may ring any other group human — the privilege is intentional:
// the spec is "如果没有特地拉谁进来, 不要让群内其他人类响铃". Auto-pull
// of the whole group on call start is gone.

const RingBody = z.object({ user_id: z.string().uuid() });

groupVoiceRoutes.post('/:id/voice/ring', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  let parsed: z.infer<typeof RingBody>;
  try {
    parsed = RingBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const callerId = c.var.userId!;
  if (parsed.user_id === callerId) {
    return jsonError(c, 400, 'invalid_body', { detail: 'cannot ring self' });
  }

  // The target must be a human participant of this group.
  const supaSvc = serviceClient(c.env);
  const { data: part } = await supaSvc
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .eq('participant_id', parsed.user_id)
    .maybeSingle();
  if (!part) {
    return jsonError(c, 404, 'not_found', { detail: 'user not in group' });
  }

  const doResp = await controlRoom(c, conversationId, '/control/invite', {
    kind: 'human',
    targetId: parsed.user_id,
    invitedBy: callerId,
  });
  if (!doResp.ok) {
    // 400 = room hasn't been started yet (the inviter must be in the call).
    if (doResp.status === 400) {
      return jsonError(c, 409, 'conflict', { detail: 'voice room not started' });
    }
    console.warn('[group-voice/ring] room DO invite failed', doResp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }

  // Resolve the caller's display name + the group title server-side so
  // the iOS PushKit handler can hand them to CallKit's CXCallUpdate
  // without a follow-up round-trip. CallKit shows these on the
  // lock-screen / full-screen incoming surface, so the names need to be
  // in the push body — there's no "I'll fetch this after answer" window.
  const [{ data: callerRow }, { data: convRow }] = await Promise.all([
    supaSvc.from('users').select('display_name').eq('id', callerId).maybeSingle(),
    supaSvc
      .from('conversations')
      .select('title')
      .eq('id', conversationId)
      .maybeSingle(),
  ]);
  const callerName =
    (callerRow?.display_name as string | null | undefined) ?? '某人';
  const groupTitle =
    (convRow?.title as string | null | undefined) ?? '群语音';

  // One UUID per ring attempt. CallKit dedups incoming calls by UUID; if
  // the same user gets rung twice for the same call (e.g. inviter
  // re-rings after decline) we deliberately mint a new UUID so the
  // second push is a fresh incoming-call surface, not a no-op.
  const callUuid = crypto.randomUUID();

  // PushKit delivers the whole top-level dict to the app — `aps` is
  // ignored on this path, but harmless. The iOS handler reads the
  // `voice_ring` keys and calls CXProvider.reportNewIncomingCall the
  // moment the push lands (mandatory under iOS 13+ VoIP rules).
  const { sent, failed } = await sendVoipRing({
    env: c.env,
    userId: parsed.user_id,
    payload: {
      extra: {
        kind: 'voice_ring',
        call_uuid: callUuid,
        conversation_id: conversationId,
        from_user_id: callerId,
        caller_display_name: callerName,
        group_title: groupTitle,
      },
    },
    // Multiple rings of the same user collapse on the device.
    collapseId: `voice-ring:${conversationId}:${parsed.user_id}`,
  });

  return c.json({ ok: true, pushed: sent, failed, call_uuid: callUuid });
});

// =============================================================================
// POST /:id/voice/cancel-invite — drop a pending invite
// =============================================================================
//
// Used when the inviter changes their mind, or when the in-call UI offers
// a "stop ringing" affordance. The user simply not answering is also
// fine — when the call ends the DO clears the pending set anyway.

const CancelInviteBody = z.object({ target_id: z.string().uuid() });

groupVoiceRoutes.post('/:id/voice/cancel-invite', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  let parsed: z.infer<typeof CancelInviteBody>;
  try {
    parsed = CancelInviteBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const resp = await controlRoom(c, conversationId, '/control/cancel-invite', {
    targetId: parsed.target_id,
  });
  if (!resp.ok) {
    console.warn('[group-voice/cancel-invite] room DO failed', resp.status);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true });
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
  if (parsed.target_type === 'bot') {
    const meetingKey = realtimeKitMeetingKey(conversationId);
    const state = await c.env.MEMORY.get<RealtimeKitRoomState>(meetingKey, 'json');
    if (state?.id) {
      const next = removeRealtimeKitBot(state, parsed.target_id);
      await putRealtimeKitRoomState(c, conversationId, next);
      await recordRealtimeKitState(c.env, conversationId, next);
    }
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
// POST /:id/voice/heartbeat — iOS keepalive
// =============================================================================
//
// iOS posts this every ~10s while a call is up. The DO times out humans
// whose heartbeat goes missing — once the last admin's gone the room
// finalizes, regardless of whether /voice/leave reached us (app killed,
// network down, SFU stream-adapter close never fired). 404 means the
// DO no longer thinks the caller is in the room: iOS should tear down.

groupVoiceRoutes.post('/:id/voice/heartbeat', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const resp = await controlRoom(c, conversationId, '/control/heartbeat', {
    humanId: c.var.userId!,
  });
  if (resp.status === 404) return jsonError(c, 404, 'not_in_room');
  if (!resp.ok) {
    console.warn('[group-voice/heartbeat] room DO failed', resp.status);
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
  const roster = (await doResp.json()) as {
    startedAt?: unknown;
    initiatorId?: unknown;
    bots?: unknown;
    humans?: unknown;
    pending?: unknown;
    diagnostics?: unknown;
  };

  return c.json({
    ok: true,
    session_id: humanSessionId,
    answer: answerSdp,
    startedAt: roster.startedAt,
    initiatorId: roster.initiatorId,
    bots: roster.bots ?? [],
    humans: roster.humans ?? [],
    pending: roster.pending ?? [],
    diagnostics: roster.diagnostics,
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
  const roster = (await resp.json()) as {
    startedAt?: unknown;
    initiatorId?: unknown;
    bots?: unknown;
    humans?: unknown;
    pending?: unknown;
    diagnostics?: unknown;
  };
  return c.json({
    ok: true,
    startedAt: roster.startedAt,
    initiatorId: roster.initiatorId,
    bots: roster.bots ?? [],
    humans: roster.humans ?? [],
    pending: roster.pending ?? [],
    diagnostics: roster.diagnostics,
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
