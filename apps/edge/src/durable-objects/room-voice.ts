import { getContainer } from '@cloudflare/containers';
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute } from '../llm/router';
import { getModelRole } from '../lib/model-roles';
import { publishToHub, type VoiceCallEvent } from '../lib/realtime-publish';
import {
  broadcastVoiceCostPreview,
  computeRealtimeKitParticipantCostUsd,
  enqueueVoiceTurnAudit,
  getRealtimeKitAudioParticipantUsdPerMinute,
  splitRealtimeUsage,
  type VoiceTurnUsage,
} from '../lib/voice-metering';
import { wallet, type WalletOwner } from '../billing/wallet-client';
import { resolveWalletSubjectKey } from '../billing/subject-key';
import { settleGroupSpend } from '../billing/group-wallet';
import { usdToPncMicros } from '../billing/pnc';
import { roomMediaToken } from './room-voice-context';
import type {
  ContainerBotSpec,
  ControlCommand,
  ControlEvent,
  MediaDiagnostics,
  RealtimeUsage,
} from './room-media-protocol';
import { isCallAdminTargetPresent } from './room-voice-policy';
import {
  buildResyncCommands,
  nextBackoffMs,
  RECONNECT_MAX_WALL_MS,
  shouldGiveUpReconnect,
} from './room-voice-reconnect';

// RoomVoiceDO — the group-voice control plane. One instance per group call
// (keyed by conversation_id). Humans and bots are Cloudflare RealtimeKit
// participants; the media container runs the bot's headless WebRTC client,
// OpenAI Realtime sockets, audio mixing and playout clock. The DO keeps
// lifecycle, permissions/roles, presence, roster, realtime broadcasts and
// billing.

// Hard wall-clock cap, mirrors RealtimeMeterDO / lib/realtime-sessions.ts.
const MAX_CALL_MS = 30 * 60 * 1000;
// Voice fallback model lives in the board's `voiceDefault` role
// (lib/model-roles.ts) — resolved per call via getModelRole(this.env, ...)
// and threaded into toContainerSpec, so ops can repoint it without a redeploy.

// iOS posts /control/heartbeat while the call is up. A human whose last
// heartbeat is older than PRESENCE_TIMEOUT_MS is swept; once the last admin
// is gone the room finalizes.
const PRESENCE_TIMEOUT_MS = 30 * 1000;
const PRESENCE_AUDIT_MS = 5 * 1000;

// Heartbeat over the DO↔container control link. The DO pings on each
// presence-audit tick (5s) and the container pongs. If no pong lands
// within HEARTBEAT_TIMEOUT_MS (two missed ticks) the link is treated as
// half-open / dead and reconnect begins. This catches a silent drop a
// `close`/`error` event would miss (e.g. the container went away without
// a clean close frame).
const HEARTBEAT_TIMEOUT_MS = 2 * PRESENCE_AUDIT_MS;

// Room-level context — everything that is not per-bot. The RTK container
// bridge only needs a private media token for its localhost page/WS
// endpoints.
interface RoomContext {
  roomId: string;
  conversationId: string;
  // Legacy route metadata context. Audit billing uses conversationId
  // and splits voice turns across present group members.
  billUserId: string;
  // The user who started this call. Always privileged.
  initiatorUserId: string;
  // Group owner + admin user IDs. Always privileged for the call's life.
  groupAdminIds: string[];
  // Wall-clock ms when /control/start ran — surfaced via roster().
  startedAt: number;
  mediaToken: string;
  realtimeKitMeetingId: string;
  realtimeKitHumanIds: string[];
}

interface PendingInvite {
  kind: 'human' | 'bot';
  invitedAt: number;
  invitedBy: string;
}

// Realtime function tools every bot gets. `leave_call` is the bot's own
// hang-up: it drops just that bot from the call.
const BASE_BOT_TOOLS = [
  {
    type: 'function',
    name: 'leave_call',
    description:
      'Leave (hang up) this voice call. Call this when you are asked to ' +
      'leave or hang up, or when you are done and have nothing more to add.',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
  },
] as const;

// Extra tools a bot gets only while it is a call-admin. Same powers as a
// human admin — but the human-admin invariant still holds.
const ADMIN_BOT_TOOLS = [
  {
    type: 'function',
    name: 'end_call',
    description: 'End the entire voice call for everyone. Call-admins only.',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    type: 'function',
    name: 'kick_participant',
    description:
      'Remove a participant — a person or another bot — from the call. ' +
      'Call-admins only. Removing the last human admin is refused.',
    parameters: {
      type: 'object',
      properties: {
        target_type: { type: 'string', enum: ['human', 'bot'] },
        target_id: { type: 'string' },
      },
      required: ['target_type', 'target_id'],
      additionalProperties: false,
    },
  },
  {
    type: 'function',
    name: 'designate_admin',
    description:
      'Grant call-admin powers to a participant (a person or a bot). ' +
      'Call-admins only.',
    parameters: {
      type: 'object',
      properties: { target_id: { type: 'string' } },
      required: ['target_id'],
      additionalProperties: false,
    },
  },
] as const;

// Per-bot configuration handed in by the control endpoint.
interface BotSpec {
  botId: string;
  model: string;
  instructions: string;
  /// Resolved per-bot voice + turn-detection block from lib/voice-config.
  voiceConfig: {
    voice: string;
    turnDetection?:
      | null
      | {
          type: 'server_vad' | 'semantic_vad';
          threshold?: number;
          prefix_padding_ms?: number;
          silence_duration_ms?: number;
          eagerness?: 'low' | 'medium' | 'high' | 'auto';
          create_response?: boolean;
          interrupt_response?: boolean;
        };
  };
  realtimeKit?: {
    meetingId: string;
    participantId: string;
    authToken: string;
  };
}

interface StartPayload {
  room: Omit<RoomContext, 'startedAt'>;
  bots: BotSpec[];
}

// Per-bot control-plane state. The audio (OpenAI socket, RTK socket,
// playout) lives in the container — here we keep only what the DO needs:
// the spec and the audit turn counter.
interface BotLeg {
  spec: BotSpec;
  turnIndex: number;
  joinedAt: number;
}

interface HumanState {
  humanId: string;
  // Wall-clock ms of the last /control/heartbeat (or initial add-human).
  lastSeenAt: number;
  joinedAt: number;
}

export class RoomVoiceDO {
  private state: DurableObjectState;
  private env: Env;
  private ctx: RoomContext | null = null;

  private bots = new Map<string, BotLeg>();
  private humans = new Map<string, HumanState>();
  private pendingInvites = new Map<string, PendingInvite>();
  private callAdminIds = new Set<string>();

  // Control WebSocket to the media container. Opened on start. If it
  // drops mid-call the DO does NOT end the call immediately — it enters a
  // bounded reconnect loop (re-dial + replay room state to a fresh
  // container session) and only finalizes if every attempt fails within
  // RECONNECT_MAX_WALL_MS. See onMediaClosed / runReconnect.
  private mediaWs: WebSocket | null = null;
  private mediaOpening: Promise<void> | null = null;

  // ── reconnect / heartbeat bookkeeping ──────────────────────────────
  // True between detecting a control-link drop and a successful resync
  // (or hard give-up). While set, sendMedia drops commands — the resync
  // replay rebuilds roster state, so transient roster commands are safe
  // to lose.
  private reconnecting = false;
  // Guards against two reconnect loops running at once (e.g. a `close`
  // event and a heartbeat timeout firing back-to-back).
  private reconnectInFlight = false;
  // 0-based attempt counter for the backoff schedule; reset on success.
  private reconnectAttempt = 0;
  // Wall-clock ms when the current reconnect episode began — the
  // RECONNECT_MAX_WALL_MS budget is measured from here.
  private reconnectStartedAt = 0;
  // Wall-clock ms of the last pong (or `ready`) seen on the control link.
  // Heartbeat compares against this to detect a half-open socket.
  private lastPongAt = 0;
  // Absolute ms deadline for the hard wall-clock call cap. Persisted so
  // the (now multiplexed) alarm handler can tell a reconnect tick apart
  // from the genuine MAX_CALL_MS expiry.
  private callDeadlineAt = 0;

  private presenceAuditTimer: ReturnType<typeof setTimeout> | null = null;
  private humanEverJoined = false;
  private closed = false;
  private cumulativePncMicros = 0;
  private latestDiagnostics: MediaDiagnostics | null = null;
  private accumulatedHumanMs = new Map<string, number>();
  private accumulatedBotMs = new Map<string, number>();

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case '/control/start':
        return this.start((await request.json()) as StartPayload);
      case '/control/sync-humans': {
        const { humanIds } = (await request.json()) as { humanIds: string[] };
        return this.syncHumans(humanIds);
      }
      case '/control/finalize':
        await this.finalize();
        return Response.json({ ok: true });
      case '/control/add-bot':
        return this.addBot((await request.json()) as BotSpec);
      case '/control/remove-bot': {
        const { botId } = (await request.json()) as { botId: string };
        await this.removeBot(botId);
        return Response.json({ ok: true });
      }
      case '/control/invite': {
        const body = (await request.json()) as {
          kind: 'human' | 'bot';
          targetId: string;
          invitedBy: string;
        };
        return this.invite(body.kind, body.targetId, body.invitedBy);
      }
      case '/control/cancel-invite': {
        const body = (await request.json()) as { targetId: string };
        return this.cancelInvite(body.targetId);
      }
      case '/control/roster':
        return Response.json(this.roster());
      case '/control/heartbeat': {
        const { humanId } = (await request.json()) as { humanId: string };
        const human = this.humans.get(humanId);
        if (!human) return Response.json({ ok: false, code: 'not_in_room' }, { status: 404 });
        human.lastSeenAt = Date.now();
        return Response.json({ ok: true });
      }
      case '/control/kick': {
        const body = (await request.json()) as {
          actorId: string;
          targetType: 'bot' | 'human';
          targetId: string;
        };
        return this.kick(body.actorId, body.targetType, body.targetId);
      }
      case '/control/designate-admin': {
        const { actorId, targetId } = (await request.json()) as {
          actorId: string;
          targetId: string;
        };
        return this.designateAdmin(actorId, targetId);
      }
      case '/control/end': {
        const { actorId } = (await request.json()) as { actorId: string };
        if (!this.isPrivileged(actorId)) {
          return new Response('forbidden', { status: 403 });
        }
        await this.finalize();
        return Response.json({ ok: true });
      }
      default:
        return new Response('not found', { status: 404 });
    }
  }

  // ── media container channel ────────────────────────────────────────

  private async ensureMedia(): Promise<void> {
    if (this.mediaWs) return;
    if (!this.mediaOpening) {
      this.mediaOpening = this.openMediaChannel().finally(() => {
        this.mediaOpening = null;
      });
    }
    await this.mediaOpening;
  }

  private async openMediaChannel(): Promise<void> {
    const ctx = this.ctx;
    if (!ctx || this.mediaWs || this.closed) return;
    const ws = await this.dialMediaChannel();
    if (!ws) return;
    // Arm the container: the RTK bridge token it must see in ?t=, and the
    // OpenAI key (passed at runtime so it stays out of the image).
    this.sendMedia({
      t: 'start',
      token: roomMediaToken(ctx),
      openaiApiKey: this.env.OPENAI_API_KEY ?? '',
    });
  }

  // Open one control WebSocket to the container and wire its handlers.
  // Does NOT send `start` — callers (initial connect vs reconnect) decide
  // what to replay. Sets this.mediaWs on success. Returns the socket or
  // null on failure.
  private async dialMediaChannel(): Promise<WebSocket | null> {
    const ctx = this.ctx;
    if (!ctx || this.mediaWs || this.closed) return null;
    try {
      const stub = getContainer(this.env.ROOM_MEDIA, ctx.roomId);
      const resp = await stub.fetch(
        new Request('https://media/control', { headers: { Upgrade: 'websocket' } }),
      );
      const ws = resp.webSocket;
      if (!ws) {
        console.warn('[room-voice] media control upgrade failed', resp.status);
        return null;
      }
      ws.accept();
      this.mediaWs = ws;
      this.lastPongAt = Date.now();
      ws.addEventListener('message', (ev) => {
        if (typeof ev.data === 'string') {
          this.onMediaEvent(ev.data).catch((err) =>
            console.warn('[room-voice] media event failed', err),
          );
        }
      });
      ws.addEventListener('close', () => {
        if (this.mediaWs === ws) {
          this.mediaWs = null;
          this.onMediaClosed('close');
        }
      });
      ws.addEventListener('error', () => {
        if (this.mediaWs === ws) {
          this.mediaWs = null;
          this.onMediaClosed('error');
        }
      });
      return ws;
    } catch (err) {
      console.warn('[room-voice] dialMediaChannel failed', err);
      return null;
    }
  }

  private sendMedia(cmd: ControlCommand): void {
    const ws = this.mediaWs;
    if (!ws) {
      // During a reconnect episode the channel is intentionally down; the
      // resync replay (start + add-bot per bot) rebuilds roster state, so
      // dropping transient commands here is safe — just log it.
      if (this.reconnecting) {
        console.warn('[room-voice] media channel reconnecting, dropping', cmd.t);
      } else {
        console.warn('[room-voice] media channel not open, dropping', cmd.t);
      }
      return;
    }
    try {
      ws.send(JSON.stringify(cmd));
    } catch {
      // socket gone — onMediaClosed will fire and the reconnect loop runs
    }
  }

  // The control link dropped (clean close, error, or a missed heartbeat).
  // Begin a bounded reconnect+resync episode rather than ending the call
  // outright. finalize() only happens if every attempt fails within the
  // wall-clock budget (see runReconnect). Guards: ignore once the call has
  // legitimately ended, and don't start a second episode if one is live.
  private onMediaClosed(reason: 'close' | 'error' | 'heartbeat'): void {
    if (this.closed) return;
    if (this.reconnecting || this.reconnectInFlight) return;
    console.warn(
      `[room-voice] media control link lost (${reason}); starting reconnect+resync`,
    );
    this.reconnecting = true;
    this.reconnectAttempt = 0;
    this.reconnectStartedAt = Date.now();
    void this.broadcastState('reconnecting');
    // Drive the first attempt immediately off the alarm so the retry loop
    // survives DO hibernation (the open control WS used to keep us awake;
    // it's gone now).
    void this.scheduleReconnectTick(0);
  }

  // Arm the alarm for the next reconnect attempt, clamped so it never
  // pushes past the hard call deadline. Driving retries off the alarm
  // (rather than setTimeout) keeps them alive if the DO hibernates while
  // the control WS is down.
  private async scheduleReconnectTick(delayMs: number): Promise<void> {
    if (this.closed || !this.reconnecting) return;
    const at = Math.min(
      Date.now() + Math.max(0, delayMs),
      this.callDeadlineAt || Date.now() + MAX_CALL_MS,
    );
    await this.state.storage.setAlarm(at);
  }

  // One reconnect attempt, invoked from the alarm dispatcher. Re-dials the
  // container, waits for the next session, replays the resync sequence,
  // and on success clears the reconnecting flag. On failure it re-arms the
  // alarm for the next backoff — or finalizes if the wall-clock budget is
  // spent. Fail-loud at every branch.
  private async runReconnect(): Promise<void> {
    if (this.closed || !this.reconnecting) return;
    if (this.reconnectInFlight) return;
    this.reconnectInFlight = true;
    const attempt = this.reconnectAttempt;
    try {
      const ws = await this.dialMediaChannel();
      if (ws) {
        // New session is live; replay room state. The container's `start`
        // handler resets any stale legs first (idempotent), so this is
        // safe even on a reused warm instance.
        const ok = await this.resyncContainer();
        if (ok) {
          console.warn(
            `[room-voice] reconnect succeeded after ${attempt + 1} attempt(s); resynced`,
          );
          this.reconnecting = false;
          this.reconnectAttempt = 0;
          await this.broadcastState('state');
          // Re-arm the alarm for the genuine call deadline.
          await this.rearmCallDeadline();
          return;
        }
        // Dial worked but resync send failed — tear the half-open socket
        // down and fall through to a retry.
        try {
          this.mediaWs?.close();
        } catch {
          // already closing
        }
        this.mediaWs = null;
      }

      // This attempt failed. Decide: retry or give up.
      this.reconnectAttempt = attempt + 1;
      const elapsed = Date.now() - this.reconnectStartedAt;
      const backoff = nextBackoffMs(this.reconnectAttempt);
      if (shouldGiveUpReconnect(elapsed, backoff, RECONNECT_MAX_WALL_MS)) {
        console.error(
          `[room-voice] reconnect GAVE UP after ${this.reconnectAttempt} attempt(s) ` +
            `(${elapsed}ms elapsed, budget ${RECONNECT_MAX_WALL_MS}ms); ending call`,
        );
        this.reconnecting = false;
        await this.finalize();
        return;
      }
      console.warn(
        `[room-voice] reconnect attempt ${this.reconnectAttempt} failed; ` +
          `retrying in ${backoff}ms (${elapsed}ms elapsed)`,
      );
      await this.scheduleReconnectTick(backoff);
    } finally {
      this.reconnectInFlight = false;
    }
  }

  // Replay the resync command sequence to the freshly-dialed session:
  // start (resets the container) then one add-bot per current bot.
  // Returns false if the channel went away mid-send.
  private async resyncContainer(): Promise<boolean> {
    const ctx = this.ctx;
    if (!ctx || !this.mediaWs) return false;
    const voiceDefault = await getModelRole(this.env, 'voiceDefault');
    const specs = [...this.bots.values()].map((leg) => this.toContainerSpec(leg.spec, voiceDefault));
    const cmds = buildResyncCommands(
      { token: roomMediaToken(ctx), openaiApiKey: this.env.OPENAI_API_KEY ?? '' },
      specs,
    );
    for (const cmd of cmds) {
      if (!this.mediaWs) return false;
      this.sendMedia(cmd);
    }
    return Boolean(this.mediaWs);
  }

  // (Re)arm the hard wall-clock call cap alarm. Stores the absolute
  // deadline so the alarm dispatcher can distinguish a deadline expiry
  // from a reconnect tick.
  private async rearmCallDeadline(): Promise<void> {
    if (this.closed) return;
    await this.state.storage.setAlarm(this.callDeadlineAt);
  }

  // Heartbeat tick — invoked from the presence audit. Pings the container
  // if the link is up, and if no pong has arrived within the timeout
  // treats the link as half-open and starts a reconnect.
  private heartbeatTick(): void {
    if (this.closed || this.reconnecting || this.reconnectInFlight) return;
    if (!this.mediaWs) return;
    const now = Date.now();
    if (this.lastPongAt > 0 && now - this.lastPongAt > HEARTBEAT_TIMEOUT_MS) {
      console.warn(
        `[room-voice] no pong for ${now - this.lastPongAt}ms; link half-open`,
      );
      // Drop the dead socket and trigger reconnect.
      const ws = this.mediaWs;
      this.mediaWs = null;
      try {
        ws?.close();
      } catch {
        // already gone
      }
      this.onMediaClosed('heartbeat');
      return;
    }
    this.sendMedia({ t: 'ping' });
  }

  private async onMediaEvent(raw: string): Promise<void> {
    let ev: ControlEvent;
    try {
      ev = JSON.parse(raw) as ControlEvent;
    } catch {
      return;
    }
    switch (ev.t) {
      case 'ready':
        // A fresh session is live — treat as a fresh heartbeat too.
        this.lastPongAt = Date.now();
        return;
      case 'pong':
        this.lastPongAt = Date.now();
        return;
      case 'bot-tool':
        await this.handleBotTool(ev.botId, ev.name, ev.callId, ev.args);
        return;
      case 'turn-usage':
        await this.settleTurn(ev.botId, ev.usage);
        return;
      case 'diagnostics':
        this.latestDiagnostics = ev.diagnostics;
        await this.broadcastState('state');
        return;
      case 'leg-closed':
        await this.onLegClosed(ev.botId);
        return;
    }
  }

  // ── lifecycle ──────────────────────────────────────────────────────

  private async start(payload: StartPayload): Promise<Response> {
    if (this.ctx) {
      this.ctx.realtimeKitHumanIds = [...new Set(payload.room.realtimeKitHumanIds)];
      await this.state.storage.put('ctx', this.ctx);
      this.syncHumanPresence(this.ctx.realtimeKitHumanIds);
      for (const spec of payload.bots) {
        await this.connectBot(spec).catch((err) =>
          console.warn('[room-voice] bot leg failed at sync', spec.botId, err),
        );
      }
      await this.broadcastState('state');
      return Response.json({ ok: true, already: true, ...this.roster() });
    }

    const ctx: RoomContext = {
      ...payload.room,
      realtimeKitHumanIds: [...new Set(payload.room.realtimeKitHumanIds)],
      startedAt: Date.now(),
    };
    this.ctx = ctx;
    this.syncHumanPresence(ctx.realtimeKitHumanIds);
    await this.state.storage.put('ctx', ctx);
    await this.ensureMedia();

    for (const spec of payload.bots) {
      await this.connectBot(spec).catch((err) =>
        console.warn('[room-voice] bot leg failed at start', spec.botId, err),
      );
    }

    this.schedulePresenceAudit();
    this.callDeadlineAt = Date.now() + MAX_CALL_MS;
    await this.state.storage.put('callDeadlineAt', this.callDeadlineAt);
    await this.state.storage.setAlarm(this.callDeadlineAt);
    await this.upsertActiveIndex();
    await this.broadcastState('state');
    return Response.json({ ok: true, ...this.roster() });
  }

  private async syncHumans(humanIds: string[]): Promise<Response> {
    if (!this.ctx) return new Response('room not started', { status: 400 });
    this.ctx.realtimeKitHumanIds = [...new Set(humanIds)];
    this.syncHumanPresence(this.ctx.realtimeKitHumanIds);
    await this.state.storage.put('ctx', this.ctx);
    await this.broadcastState('state');
    return Response.json({ ok: true });
  }

  private syncHumanPresence(humanIds: string[]): void {
    const now = Date.now();
    const active = new Set(humanIds);
    for (const id of active) {
      const existing = this.humans.get(id);
      this.humans.set(id, {
        humanId: id,
        lastSeenAt: existing?.lastSeenAt ?? now,
        joinedAt: existing?.joinedAt ?? now,
      });
    }
    for (const id of this.humans.keys()) {
      if (!active.has(id)) {
        this.finishHumanParticipant(id, now);
        this.humans.delete(id);
      }
    }
    if (this.humans.size > 0) this.humanEverJoined = true;
  }

  private async upsertActiveIndex(): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;
    try {
      await serviceClient(this.env)
        .from('voice_active_calls')
        .upsert(
          {
            conversation_id: ctx.conversationId,
            started_at: new Date(ctx.startedAt).toISOString(),
            initiator_id: ctx.initiatorUserId,
          },
          { onConflict: 'conversation_id' },
        );
    } catch (err) {
      console.warn('[room-voice] active-index upsert failed', err);
    }
  }

  private async clearActiveIndex(): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;
    try {
      await serviceClient(this.env)
        .from('voice_active_calls')
        .delete()
        .eq('conversation_id', ctx.conversationId);
    } catch (err) {
      console.warn('[room-voice] active-index clear failed', err);
    }
  }

  private async addBot(spec: BotSpec): Promise<Response> {
    if (!this.ctx) return new Response('room not started', { status: 400 });
    if (this.bots.has(spec.botId)) {
      return Response.json({ ok: true, already: true });
    }
    try {
      await this.connectBot(spec);
    } catch (err) {
      console.warn('[room-voice] add-bot leg failed', spec.botId, err);
      return new Response('bot leg failed', { status: 502 });
    }
    this.pendingInvites.delete(spec.botId);
    await this.broadcastState('state');
    return Response.json({ ok: true });
  }

  private async invite(
    kind: 'human' | 'bot',
    targetId: string,
    invitedBy: string,
  ): Promise<Response> {
    if (!this.ctx) return new Response('room not started', { status: 400 });
    if (kind === 'human' && this.humans.has(targetId)) {
      return Response.json({ ok: true, already: 'joined' });
    }
    if (kind === 'bot' && this.bots.has(targetId)) {
      return Response.json({ ok: true, already: 'joined' });
    }
    this.pendingInvites.set(targetId, { kind, invitedAt: Date.now(), invitedBy });
    await this.broadcastState('state');
    return Response.json({ ok: true });
  }

  private async cancelInvite(targetId: string): Promise<Response> {
    if (this.pendingInvites.delete(targetId)) {
      await this.broadcastState('state');
    }
    return Response.json({ ok: true });
  }

  private async removeBot(botId: string): Promise<void> {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.finishBotParticipant(botId, Date.now());
    this.bots.delete(botId);
    this.callAdminIds.delete(botId);
    // Tell the container to drop the bot's OpenAI + RealtimeKit sockets.
    this.sendMedia({ t: 'remove-bot', botId });
    // A human-only call is fine — the room ends with its last human, not
    // its last bot (see removeHuman).
    await this.broadcastState('state');
  }

  // Bring up one bot: register it in the container, which joins the same
  // RealtimeKit meeting as a headless WebRTC participant and opens its
  // OpenAI Realtime socket.
  private async connectBot(spec: BotSpec): Promise<void> {
    if (!this.ctx) throw new Error('room not started');

    const leg: BotLeg = {
      spec,
      turnIndex: 0,
      joinedAt: Date.now(),
    };
    this.bots.set(spec.botId, leg);

    await this.ensureMedia();
    this.sendMedia({
      t: 'add-bot',
      spec: this.toContainerSpec(spec, await getModelRole(this.env, 'voiceDefault')),
    });
  }

  // Translate the DO's BotSpec into the container's wire spec — flattening
  // the voice block and resolving the tool set (the DO owns permissions).
  // `defaultModel` is the board-configured voiceDefault, resolved by the
  // async caller (this fn stays sync — no env access here).
  private toContainerSpec(spec: BotSpec, defaultModel: string): ContainerBotSpec {
    return {
      botId: spec.botId,
      model: spec.model || defaultModel,
      instructions: spec.instructions,
      voice: spec.voiceConfig.voice || 'marin',
      turnDetection: spec.voiceConfig.turnDetection,
      tools: this.toolsFor(spec.botId),
      ...(spec.realtimeKit ? { realtimeKit: spec.realtimeKit } : {}),
    };
  }

  private roster(): {
    startedAt: number;
    initiatorId: string;
    bots: Array<{ botId: string }>;
    humans: Array<{ humanId: string }>;
    pending: Array<{ id: string; kind: 'human' | 'bot'; invitedAt: number; invitedBy: string }>;
    diagnostics?: MediaDiagnostics;
  } {
    const bots = [...this.bots.values()].map((leg) => ({ botId: leg.spec.botId }));
    const humans = [...this.humans.values()].map((h) => ({ humanId: h.humanId }));
    const pending: Array<{
      id: string;
      kind: 'human' | 'bot';
      invitedAt: number;
      invitedBy: string;
    }> = [];
    for (const [id, inv] of this.pendingInvites) {
      pending.push({ id, kind: inv.kind, invitedAt: inv.invitedAt, invitedBy: inv.invitedBy });
    }
    return {
      startedAt: this.ctx?.startedAt ?? 0,
      initiatorId: this.ctx?.initiatorUserId ?? '',
      bots,
      humans,
      pending,
      ...(this.latestDiagnostics && { diagnostics: this.latestDiagnostics }),
    };
  }

  private async removeHuman(humanId: string): Promise<void> {
    const human = this.humans.get(humanId);
    if (!human) return;
    this.finishHumanParticipant(humanId, Date.now());
    this.humans.delete(humanId);
    // A voice room must always have a human admin. Once none remains the
    // call ends.
    if (this.humanEverJoined && !this.humanAdminPresent()) {
      await this.finalize();
      return;
    }
    await this.broadcastState('state');
  }

  // ── permissions & roster ───────────────────────────────────────────

  private isPrivileged(actorId: string): boolean {
    const ctx = this.ctx;
    if (!ctx) return false;
    return (
      actorId === ctx.initiatorUserId ||
      ctx.groupAdminIds.includes(actorId) ||
      this.callAdminIds.has(actorId)
    );
  }

  private humanAdminPresent(exclude?: string): boolean {
    for (const humanId of this.humans.keys()) {
      if (humanId === exclude) continue;
      if (this.isPrivileged(humanId)) return true;
    }
    return false;
  }

  private async kick(
    actorId: string,
    targetType: 'bot' | 'human',
    targetId: string,
  ): Promise<Response> {
    if (!this.isPrivileged(actorId)) {
      return new Response('forbidden', { status: 403 });
    }
    if (targetType === 'bot') {
      await this.removeBot(targetId);
      return Response.json({ ok: true });
    }
    if (!this.humans.has(targetId)) {
      return Response.json({ ok: true, already: true });
    }
    if (this.isPrivileged(targetId) && !this.humanAdminPresent(targetId)) {
      return new Response('would leave the room without a human admin', {
        status: 409,
      });
    }
    await this.removeHuman(targetId);
    return Response.json({ ok: true });
  }

  private designateAdmin(actorId: string, targetId: string): Response {
    if (!this.isPrivileged(actorId)) {
      return new Response('forbidden', { status: 403 });
    }
    if (!isCallAdminTargetPresent(targetId, this.humans.keys(), this.bots.keys())) {
      return new Response('target is not in the room', { status: 404 });
    }
    this.callAdminIds.add(targetId);
    const leg = this.bots.get(targetId);
    if (leg) this.pushBotTools(leg);
    return Response.json({ ok: true });
  }

  private async broadcastState(event: 'state' | 'ended' | 'reconnecting'): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;
    const snapshot = this.roster();
    const payload: VoiceCallEvent = {
      type: 'voice_call',
      event,
      conversation_id: ctx.conversationId,
      started_at: snapshot.startedAt,
      initiator_id: snapshot.initiatorId,
      participants: [
        ...snapshot.humans.map((h) => ({ kind: 'human' as const, id: h.humanId })),
        ...snapshot.bots.map((b) => ({ kind: 'bot' as const, id: b.botId })),
      ],
      pending: snapshot.pending.map((p) => ({
        kind: p.kind,
        id: p.id,
        invited_by: p.invitedBy,
      })),
      diagnostics: snapshot.diagnostics,
    };
    await publishToHub(this.env, `conv:${ctx.conversationId}`, payload).catch((err) =>
      console.warn('[room-voice] broadcast failed', err),
    );
  }

  // ── bot tools (container reports invocations; the DO decides) ───────

  // The tool set a bot's realtime session should expose. Every bot can hang
  // itself up; a call-admin bot also gets the admin tools.
  private toolsFor(botId: string): unknown[] {
    return this.isPrivileged(botId)
      ? [...BASE_BOT_TOOLS, ...ADMIN_BOT_TOOLS]
      : [...BASE_BOT_TOOLS];
  }

  // Re-push a bot's tool set to the container — used when it is designated
  // call-admin mid-call and should gain the admin tools.
  private pushBotTools(leg: BotLeg): void {
    this.sendMedia({
      t: 'update-tools',
      botId: leg.spec.botId,
      tools: this.toolsFor(leg.spec.botId),
    });
  }

  // The container's media leg for a bot closed (its OpenAI or RTK socket
  // died). A bot leg dying doesn't end the call — humans can still talk;
  // the room ends with its last human.
  private async onLegClosed(botId: string): Promise<void> {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.finishBotParticipant(botId, Date.now());
    this.bots.delete(botId);
    this.callAdminIds.delete(botId);
    await this.broadcastState('state');
  }

  // Execute a tool the bot invoked (relayed by the container). leave_call /
  // end_call tear the bot (or room) down, so they get no tool result — the
  // socket is gone. The others reply via the container so the bot can
  // acknowledge verbally.
  private async handleBotTool(
    botId: string,
    name: string,
    callId: string,
    argsJson: string | undefined,
  ): Promise<void> {
    if (!this.bots.has(botId)) return;
    let args: { target_type?: unknown; target_id?: unknown } = {};
    try {
      if (argsJson) args = JSON.parse(argsJson);
    } catch {
      // malformed args — treated as empty below
    }

    if (name === 'leave_call') {
      await this.removeBot(botId);
      return;
    }

    if (!this.isPrivileged(botId)) {
      this.sendMedia({
        t: 'tool-result',
        botId,
        callId,
        output: 'refused: you are not a call-admin',
      });
      return;
    }

    switch (name) {
      case 'end_call':
        await this.finalize();
        return;
      case 'kick_participant': {
        const targetType = args.target_type === 'human' ? 'human' : 'bot';
        const targetId = typeof args.target_id === 'string' ? args.target_id : '';
        const resp = await this.kick(botId, targetType, targetId);
        this.sendMedia({
          t: 'tool-result',
          botId,
          callId,
          output: resp.ok ? 'ok' : `refused: ${await resp.text()}`,
        });
        return;
      }
      case 'designate_admin': {
        const targetId = typeof args.target_id === 'string' ? args.target_id : '';
        if (!isCallAdminTargetPresent(targetId, this.humans.keys(), this.bots.keys())) {
          this.sendMedia({
            t: 'tool-result',
            botId,
            callId,
            output: 'refused: target is not in the room',
          });
          return;
        }
        this.callAdminIds.add(targetId);
        const targetLeg = this.bots.get(targetId);
        if (targetLeg) this.pushBotTools(targetLeg);
        this.sendMedia({ t: 'tool-result', botId, callId, output: 'ok' });
        return;
      }
      default:
        this.sendMedia({ t: 'tool-result', botId, callId, output: `refused: unknown tool ${name}` });
    }
  }

  // ── presence ───────────────────────────────────────────────────────

  private schedulePresenceAudit(): void {
    if (this.closed) return;
    this.presenceAuditTimer = setTimeout(() => {
      void this.auditPresence().finally(() => this.schedulePresenceAudit());
    }, PRESENCE_AUDIT_MS);
  }

  private async auditPresence(): Promise<void> {
    if (this.closed) return;
    // Heartbeat the control link on every audit tick — independent of
    // human presence, so a drop is detected even before anyone has
    // joined.
    this.heartbeatTick();
    if (!this.humanEverJoined) return;
    const now = Date.now();
    const stale: string[] = [];
    for (const [humanId, h] of this.humans) {
      if (now - h.lastSeenAt > PRESENCE_TIMEOUT_MS) stale.push(humanId);
    }
    for (const humanId of stale) {
      console.warn('[room-voice] presence timeout — removing', humanId);
      await this.removeHuman(humanId);
      if (this.closed) return;
    }
  }

  // ── billing ────────────────────────────────────────────────────────

  private finishHumanParticipant(humanId: string, atMs: number): void {
    const human = this.humans.get(humanId);
    if (!human) return;
    this.addParticipantMs(this.accumulatedHumanMs, humanId, atMs - human.joinedAt);
  }

  private finishBotParticipant(botId: string, atMs: number): void {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.addParticipantMs(this.accumulatedBotMs, botId, atMs - leg.joinedAt);
  }

  private addParticipantMs(target: Map<string, number>, id: string, deltaMs: number): void {
    if (!Number.isFinite(deltaMs) || deltaMs <= 0) return;
    target.set(id, (target.get(id) ?? 0) + deltaMs);
  }

  private humanParticipantSeconds(atMs: number): Map<string, number> {
    const out = new Map<string, number>();
    for (const [userId, ms] of this.accumulatedHumanMs) {
      if (ms > 0) out.set(userId, ms / 1000);
    }
    for (const [userId, human] of this.humans) {
      const seconds = Math.max(0, atMs - human.joinedAt) / 1000;
      if (seconds > 0) out.set(userId, (out.get(userId) ?? 0) + seconds);
    }
    return out;
  }

  private botParticipantSeconds(atMs: number): number {
    let totalMs = 0;
    for (const ms of this.accumulatedBotMs.values()) totalMs += Math.max(0, ms);
    for (const leg of this.bots.values()) totalMs += Math.max(0, atMs - leg.joinedAt);
    return totalMs / 1000;
  }

  private async settleTurn(botId: string, usage: RealtimeUsage): Promise<void> {
    const ctx = this.ctx;
    if (!ctx || this.closed) return;
    const leg = this.bots.get(botId);
    if (!leg) return;

    const supa = serviceClient(this.env);
    let route;
    try {
      route = await resolveRoute(supa, this.env, {
        modelSlug: leg.spec.model || (await getModelRole(this.env, 'voiceDefault')),
        preferProvider: 'openai',
        metadata: { userId: ctx.billUserId, conversationId: ctx.conversationId },
      });
    } catch (err) {
      console.warn('[room-voice] resolveRoute failed', err);
      return;
    }

    const turnUsage = splitRealtimeUsage(usage);

    await enqueueVoiceTurnAudit({
      env: this.env,
      route,
      userId: ctx.billUserId,
      conversationId: ctx.conversationId,
      usage: turnUsage,
      source: 'group_voice_call',
      roomId: ctx.roomId,
      turnIndex: leg.turnIndex++,
      botId: leg.spec.botId,
      // Humans in the room at this turn — recorded on the audit row for
      // diagnostics. Billing v2 settles the voice turn against the group's
      // subject wallet (via persistAuditMessage), not a per-head split.
      presentUserIds: [...this.humans.keys()],
    });

    void this.broadcastCost(supa, route?.modelToCall, turnUsage);
  }

  private async broadcastCost(
    supa: ReturnType<typeof serviceClient>,
    modelToCall: string | undefined,
    usage: VoiceTurnUsage,
  ): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;
    this.cumulativePncMicros = await broadcastVoiceCostPreview({
      env: this.env,
      supa,
      conversationId: ctx.conversationId,
      sessionId: ctx.roomId,
      modelToCall,
      usage,
      cumulativePncMicros: this.cumulativePncMicros,
      logPrefix: '[room-voice]',
    });
  }

  private async settleRealtimeKitMediaCost(): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;

    const atMs = Date.now();
    const userSeconds = this.humanParticipantSeconds(atMs);
    let humanSeconds = 0;
    for (const seconds of userSeconds.values()) humanSeconds += seconds;
    if (humanSeconds <= 0) return;

    const botSeconds = this.botParticipantSeconds(atMs);
    const participantSeconds = humanSeconds + botSeconds;
    if (participantSeconds <= 0) return;

    const supa = serviceClient(this.env);
    const price = await getRealtimeKitAudioParticipantUsdPerMinute(supa);
    const costUsd = computeRealtimeKitParticipantCostUsd(participantSeconds, price);
    if (costUsd <= 0) return;

    // Billing P2: the RealtimeKit media cost (participant-minutes) is
    // debited from the responsible subject's WalletDO, category
    // 'realtimekit_media'. Owner = the group's responsible subject (the
    // group wallet, design §8), falling back to the billing user. The DO
    // converts vendor USD → pnc_micros (no platform markup, design §9),
    // decrements its strong-consistent cache, and queues the usage for
    // flush to Polar. The legacy billing-v2 settleUsage/packs path is gone.
    const owner = await this.resolveVoiceBillingOwner(supa, ctx);
    if (!owner) return;
    // 钱包路由键:群主体原样,个人解析成其 user_account subject id
    // (见 billing/subject-key.ts)。解析不到就不计费 + 报错级日志 —— 不猜键。
    let subjectId: string;
    try {
      subjectId = await resolveWalletSubjectKey(supa, owner);
    } catch (err) {
      console.error('[room-voice] billing subject unresolved — call left unbilled', ctx.roomId, err);
      return;
    }

    // One-shot at finalize → a stable dedupeId per call instance keeps the
    // debit idempotent under any re-entry / retry.
    const dedupeId = `${ctx.roomId}:realtimekit_media`;
    const micros = usdToPncMicros(costUsd);
    const meta = {
      room_id: ctx.roomId,
      conversation_id: ctx.conversationId,
      realtimekit_meeting_id: ctx.realtimeKitMeetingId,
      participant_seconds: participantSeconds,
      human_participant_seconds: humanSeconds,
      bot_participant_seconds: botSeconds,
      participant_minute_price_usd: price,
      vendor_cost_usd: costUsd,
      present_user_seconds: Object.fromEntries(userSeconds),
    };
    try {
      // 群(owner=subject)走 settleGroupSpend:实缴池衰减 + 认缴成员个人钱包直扣;
      // 1v1(owner=user)直扣其个人钱包。
      if (owner.kind === 'subject') {
        await settleGroupSpend({ env: this.env, supa, subjectId, spendMicros: micros, category: 'realtimekit_media', dedupeId, meta });
      } else {
        await wallet.debit(this.env, subjectId, micros, { category: 'realtimekit_media', dedupeId, meta });
      }
    } catch (err) {
      // Billing failures must never break call teardown.
      console.warn('[room-voice] realtimekit_media debit failed', err);
    }
  }

  /// Resolve the v2 billing owner for this room: the conversation's
  /// responsible subject (group wallet) if set, else the billing user.
  private async resolveVoiceBillingOwner(
    supa: ReturnType<typeof serviceClient>,
    ctx: NonNullable<typeof this.ctx>,
  ): Promise<WalletOwner | null> {
    const { data } = await supa
      .from('conversations')
      .select('responsible_subject_id')
      .eq('id', ctx.conversationId)
      .maybeSingle();
    const sid = data?.responsible_subject_id;
    if (typeof sid === 'string' && sid.length > 0) {
      return { kind: 'subject', subjectId: sid };
    }
    return ctx.billUserId ? { kind: 'user', userId: ctx.billUserId } : null;
  }

  // ── teardown ───────────────────────────────────────────────────────

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    // Stop any reconnect episode from racing teardown.
    this.reconnecting = false;
    await this.settleRealtimeKitMediaCost();
    // Notify the conv channel first — once we tear down the snapshot is
    // meaningless.
    await this.broadcastState('ended');
    await this.clearActiveIndex();
    if (this.presenceAuditTimer) clearTimeout(this.presenceAuditTimer);
    this.presenceAuditTimer = null;

    // Tell the container to tear down its sockets, then drop the channel.
    this.sendMedia({ t: 'end' });
    try {
      this.mediaWs?.close();
    } catch {
      // already closing
    }
    this.mediaWs = null;

    this.bots.clear();
    this.humans.clear();
    this.pendingInvites.clear();

    await this.state.storage.deleteAlarm().catch(() => undefined);
    await this.state.storage.deleteAll().catch(() => undefined);
  }

  // The alarm is multiplexed: it fires either for a reconnect retry tick
  // (while the control link is down) or for the genuine MAX_CALL_MS wall-
  // clock cap. Distinguish by the reconnecting flag + the persisted
  // deadline so a reconnect tick doesn't prematurely end the call and a
  // deadline expiry still ends it.
  async alarm(): Promise<void> {
    if (this.closed) return;
    if (!this.callDeadlineAt) {
      const stored = await this.state.storage.get<number>('callDeadlineAt');
      if (typeof stored === 'number') this.callDeadlineAt = stored;
    }
    // Genuine wall-clock cap reached — end regardless of reconnect state.
    if (this.callDeadlineAt && Date.now() >= this.callDeadlineAt) {
      console.warn('[room-voice] max call duration reached; ending call');
      await this.finalize();
      return;
    }
    // Otherwise this is a reconnect retry tick.
    if (this.reconnecting) {
      await this.runReconnect();
      return;
    }
    // Spurious wake (no deadline hit, not reconnecting) — re-arm the
    // deadline so the hard cap still fires.
    await this.rearmCallDeadline();
  }
}
