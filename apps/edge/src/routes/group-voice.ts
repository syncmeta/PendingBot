// Group-voice control surface — the authenticated, user-facing side of
// the group-voice bridge. Mounted at /v1/groups alongside groupRoutes:
//
//   POST /v1/groups/:id/voice/bootstrap        create/join the RTK meeting
//   POST /v1/groups/:id/voice/add-bot          add a bot to the call
//   POST /v1/groups/:id/voice/ring             ring a human into the call
//   POST /v1/groups/:id/voice/cancel-invite    drop a pending invite
//   GET  /v1/groups/:id/voice/roster           current roster (re-sync)
//   POST /v1/groups/:id/voice/kick             remove a bot or human
//   POST /v1/groups/:id/voice/designate-admin  grant call-admin powers
//   POST /v1/groups/:id/voice/leave            the caller leaves the call
//   POST /v1/groups/:id/voice/heartbeat        iOS keepalive; absence == gone
//   POST /v1/groups/:id/voice/end              tear the whole call down
//
// /bootstrap creates or reuses a Cloudflare RealtimeKit meeting and mints
// the caller's WebRTC participant token. Bots are NOT auto-pulled, and
// humans are NOT auto-rung. The caller alone is in the room until they
// tap "叫机器人来" (/add-bot) or "叫真人来" (/ring) inside the call UI.
//
// Each endpoint requires a Supabase JWT and re-proves the caller is a
// participant of the group. The handlers assemble each bot's persona
// server-side (it never reaches a client) and forward a control message
// to the room's RoomVoiceDO, which owns the RTK<->OpenAI audio bridge.
//
// kick / designate-admin / end are privileged: the RoomVoiceDO holds the
// initiator / group-admin / call-admin sets and is the single authority
// on who may do what — these handlers just forward the caller's id.
//
import { Hono } from 'hono';
import type { Context } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { getModelRole } from '../lib/model-roles';
import { buildSystemPrompt } from '../llm/builder';
import { getBotMemory } from '../lib/memory';
import { resolveLocale } from '../i18n/locale';
import { jsonError } from '../lib/http-error';
import { UUID_RE } from '../lib/ids';
import { sendVoipRing } from '../lib/push';
import { trackEvent, AnalyticsEvent } from '../lib/track';
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
import {
  isGroupBotParticipant,
  isGroupHumanParticipant,
  listGroupAdminUserIds,
  loadGroupConversationForUser,
  requireGroupRole,
} from '../lib/route-authz';
import type { AppBindings } from '../types';

export const groupVoiceRoutes = new Hono<AppBindings>();
groupVoiceRoutes.use('*', requireSession());

// Default realtime model when a bot's config doesn't pin one lives in the
// board's `voiceDefault` role (lib/model-roles.ts) — resolved per call via
// getModelRole. (Voice id + turn-detection defaults live in lib/voice-config.)
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
  // Legacy caller context for route metadata. Audit billing uses
  // conversationId and splits group voice turns across present members.
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

  const loaded = await loadGroupConversationForUser(
    c.env,
    c.var.userJwt!,
    userId,
    conversationId,
  );
  if (!loaded.ok && loaded.code === 'database_error') {
    return { ok: false, res: jsonError(c, 500, 'database_error', { detail: loaded.detail }) };
  }
  if (!loaded.ok && loaded.code === 'not_found') {
    return { ok: false, res: jsonError(c, 404, 'conversation_not_found') };
  }
  if (!loaded.ok) {
    return { ok: false, res: jsonError(c, 403, 'not_a_participant') };
  }

  // Prefer the group creator as route metadata context; billing ownership
  // is resolved later from conversationId by the audit layer.
  const supaSvc = serviceClient(c.env);
  const { data: meta } = await supaSvc
    .from('conversation_group_meta')
    .select('created_by')
    .eq('conversation_id', conversationId)
    .maybeSingle();
  const billUserId = meta?.created_by ?? loaded.conversation.user_id ?? userId;

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
    c.env,
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
    model: configString(bot.config, 'voiceModel') ?? (await getModelRole(c.env, 'voiceDefault')),
    instructions,
    voiceConfig: resolveVoiceConfig(bot.config),
  };
}

// The room DO is keyed by conversation_id; one control message per call.
function roomStub(c: Context<AppBindings>, conversationId: string) {
  return c.env.ROOM_VOICE.get(c.env.ROOM_VOICE.idFromName(conversationId));
}

function realtimeKitMeetingKey(conversationId: string): string {
  return `group-voice:realtimekit:${conversationId}`;
}

async function loadGroupAdminIds(
  c: Context<AppBindings>,
  conversationId: string,
): Promise<string[]> {
  const result = await listGroupAdminUserIds(c.env, conversationId);
  if (!result.ok) {
    console.warn('[group-voice] admin lookup failed', result.detail ?? result.code);
    return [];
  }
  return result.userIds;
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

  const role = await requireGroupRole(c.env, conversationId, userId, ['owner', 'admin']);
  return role.ok;
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
  return controlRoom(c, loaded.conversationId, '/control/start', {
    room: {
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
  const resp = await controlRoom(c, conversationId, '/control/sync-humans', {
    humanIds: state.humanIds,
  }).catch(() => null);
  if (resp && !resp.ok && resp.status !== 400) {
    console.warn('[group-voice/realtimekit] human sync failed', resp.status);
  }
}

// =============================================================================
// POST /:id/voice/bootstrap
// =============================================================================
//
// Creates/reuses a RealtimeKit meeting, returns the caller's participant
// token, and mirrors the room lifecycle into the active-call index +
// conv-channel frames.

const RealtimeKitBootstrapBody = z.object({
  bot_id: z.string().uuid().optional(),
});

groupVoiceRoutes.post('/:id/voice/bootstrap', async (c) => {
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
    const [part, { data: botRow }] = await Promise.all([
      isGroupBotParticipant(c.env, conversationId, parsed.bot_id),
      supaSvc
        .from('bots')
        .select('id, display_name, voice_call_enabled')
        .eq('id', parsed.bot_id)
        .maybeSingle(),
    ]);
    if (!part.ok) return jsonError(c, 404, 'not_found', { detail: 'bot not in group' });
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
    // True only for the participant who opens the room — used below to fire
    // `voice_call_started` once per call rather than once per join.
    const isNewGroupCall = !meeting.id;
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
    const roomResp = await startRealtimeKitRoomControl(c, loaded.ctx, state, []);
    if (!roomResp.ok) {
      console.warn('[group-voice/bootstrap] room control sync failed', roomResp.status);
      return jsonError(c, 502, 'voice_upstream_failed');
    }
    if (isNewGroupCall) {
      trackEvent(c, AnalyticsEvent.VoiceCallStarted, {
        kind: 'group',
        conversation_id: conversationId,
      });
    }
    const roster = (await roomResp.json().catch(() => ({}))) as {
      bots?: unknown;
      humans?: unknown;
      pending?: unknown;
      diagnostics?: unknown;
    };

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
      bots: roster.bots ?? [],
      humans: roster.humans ?? [],
      pending: roster.pending ?? [],
      diagnostics: roster.diagnostics,
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
    console.warn('[group-voice/bootstrap] failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
});

// =============================================================================
// POST /:id/voice/leave — the caller leaves the call
// =============================================================================

groupVoiceRoutes.post('/:id/voice/leave', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const meetingKey = realtimeKitMeetingKey(conversationId);
  const state = await c.env.MEMORY.get<RealtimeKitRoomState>(meetingKey, 'json');
  if (!state?.id) {
    await recordRealtimeKitEnded(c.env, conversationId);
    await controlRoom(c, conversationId, '/control/finalize', {}).catch(() => null);
    return c.json({ ok: true, ended: true });
  }

  const next = removeRealtimeKitHuman(state, c.var.userId!);
  if (next.humanIds.length === 0) {
    await c.env.MEMORY.delete(meetingKey);
    await recordRealtimeKitEnded(c.env, conversationId);
    await controlRoom(c, conversationId, '/control/finalize', {}).catch((err) =>
      console.warn('[group-voice/leave] room finalize failed', err),
    );
    trackEvent(c, AnalyticsEvent.VoiceCallEnded, {
      kind: 'group',
      conversation_id: conversationId,
      reason: 'last_human_left',
    });
    return c.json({ ok: true, ended: true });
  }

  await putRealtimeKitRoomState(c, conversationId, next);
  await recordRealtimeKitState(c.env, conversationId, next);
  await syncRealtimeKitRoomHumans(c, conversationId, next);
  return c.json({ ok: true, ended: false });
});

// =============================================================================
// POST /:id/voice/end — end the call for everyone
// =============================================================================

groupVoiceRoutes.post('/:id/voice/end', async (c) => {
  const loaded = await loadGroupContext(c);
  if (!loaded.ok) return loaded.res;
  const { conversationId } = loaded.ctx;

  const meetingKey = realtimeKitMeetingKey(conversationId);
  const state = await c.env.MEMORY.get<RealtimeKitRoomState>(meetingKey, 'json');
  if (!state?.id) {
    await recordRealtimeKitEnded(c.env, conversationId);
    await controlRoom(c, conversationId, '/control/finalize', {}).catch(() => null);
    return c.json({ ok: true, ended: true });
  }

  if (!(await isRealtimeKitEndAllowed(c, conversationId, state))) {
    return jsonError(c, 403, 'forbidden');
  }

  await c.env.MEMORY.delete(meetingKey);
  await recordRealtimeKitEnded(c.env, conversationId);
  await controlRoom(c, conversationId, '/control/finalize', {}).catch((err) =>
    console.warn('[group-voice/end] room finalize failed', err),
  );
  trackEvent(c, AnalyticsEvent.VoiceCallEnded, {
    kind: 'group',
    conversation_id: conversationId,
    reason: 'ended_for_all',
  });

  const app = realtimeKitAppFromEnv(c.env);
  if (app) {
    await kickAllRealtimeKitParticipants(app, state.id).catch((err) =>
      console.warn('[group-voice/end] kick-all failed', err),
    );
  }

  return c.json({ ok: true, ended: true });
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
  const [part, { data: botRow }] = await Promise.all([
    isGroupBotParticipant(c.env, conversationId, parsed.bot_id),
    supaSvc
      .from('bots')
      .select('id, display_name, voice_call_enabled')
      .eq('id', parsed.bot_id)
      .maybeSingle(),
  ]);
  if (!part.ok) return jsonError(c, 404, 'not_found', { detail: 'bot not in group' });
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
      console.warn('[group-voice/add-bot] room DO failed', roomResp.status);
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
    console.warn('[group-voice/add-bot] failed', err);
    return jsonError(c, 502, 'voice_upstream_failed', { detail: String(err) });
  }
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
  const part = await isGroupHumanParticipant(c.env, conversationId, parsed.user_id);
  if (!part.ok) {
    return jsonError(c, 404, 'not_found', { detail: 'user not in group' });
  }

  const supaSvc = serviceClient(c.env);

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
  if (resp.status === 404) {
    return jsonError(c, 404, 'not_found', { detail: 'target not in room' });
  }
  if (!resp.ok) {
    console.warn('[group-voice/designate-admin] room DO failed', resp.status);
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
// network down, WebRTC participant disappeared). 404 means the
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
// GET /:id/voice/roster — current bot roster, for mid-call re-sync
// =============================================================================
//
// Lets a client that added/kicked a participant mid-call pull the current
// RealtimeKit room roster and diagnostics.

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
