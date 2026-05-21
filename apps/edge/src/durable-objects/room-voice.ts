import { getContainer } from '@cloudflare/containers';
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute, enqueueAudit, computeVoiceCost } from '../llm/router';
import { getMarkup, usdToPnd } from '../lib/billing';
import { publishToHub, type VoiceCallEvent } from '../lib/realtime-publish';
import { createStreamAdapter, createIngestAdapter, closeAdapter, type SfuApp } from '../lib/sfu';
import type {
  ContainerBotSpec,
  ControlCommand,
  ControlEvent,
  RealtimeUsage,
} from './room-media-protocol';

// RoomVoiceDO — the group-voice control plane. One instance per group call
// (keyed by conversation_id). It owns everything EXCEPT the real-time audio
// loop, which it delegates to a media container (apps/voice-container,
// reached via env.ROOM_MEDIA). The container does the choppy-sensitive work
// — SFU adapter PCM, mixing, the OpenAI Realtime sockets, and a steady
// bot-voice playout clock — in a real OS process with reliable timers,
// instead of in a workerd isolate whose scheduling jitter caused the
// stutter. See apps/voice-container/src/{index,room,protocol}.ts.
//
//   humans (WebRTC) ─▶ SFU ─▶ adapters ─▶ media container ─▶ OpenAI
//   bot voice ◀── container (playout clock) ◀── OpenAI ───────┘
//
// What stays here: lifecycle, permissions/roles, presence (heartbeat),
// roster + realtime broadcast, billing, and the SFU adapter HTTP lifecycle
// (create/close — the adapter `endpoint` points at the container). The DO
// and container speak a small JSON protocol over one control WebSocket:
// the DO sends commands (start / add-bot / ...), the container reports the
// two things it learns from the OpenAI leg — tool calls and per-turn usage.

// Hard wall-clock cap, mirrors RealtimeMeterDO / lib/realtime-sessions.ts.
const MAX_CALL_MS = 30 * 60 * 1000;
const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';

// A voice room exists only for its humans. If nobody joins within this
// window after start, end the call.
const JOIN_GRACE_MS = 90 * 1000;

// iOS posts /control/heartbeat while the call is up. A human whose last
// heartbeat is older than PRESENCE_TIMEOUT_MS is swept; once the last admin
// is gone the room finalizes.
const PRESENCE_TIMEOUT_MS = 30 * 1000;
const PRESENCE_AUDIT_MS = 5 * 1000;

// Room-level context — everything that is not per-bot.
interface RoomContext {
  roomId: string;
  conversationId: string;
  // Whose balance the voice tokens bill to (group creator today; M6's
  // splitAndDebit will replace it with a real split).
  billUserId: string;
  // The user who started this call. Always privileged.
  initiatorUserId: string;
  // Group owner + admin user IDs. Always privileged for the call's life.
  groupAdminIds: string[];
  // wss:// origin the SFU can dial back, e.g. "wss://api.pendingname.com".
  publicWsBase: string;
  // Route prefix on the edge worker that forwards adapter WS upgrades to
  // the media container, e.g. "/v1/realtime-sfu".
  adapterPath: string;
  // Shared secret echoed in the adapter endpoint URL so only the SFU
  // dialling our published endpoint is accepted (the container checks it).
  adapterToken: string;
  // Wall-clock ms when /control/start ran — surfaced via roster().
  startedAt: number;
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
}

interface StartPayload {
  room: RoomContext;
  bots: BotSpec[];
}

interface HumanTrack {
  humanId: string;
  sfuSessionId: string;
  sfuTrackName: string;
}

// Per-bot control-plane state. The audio (OpenAI socket, ingest socket,
// playout) lives in the container — here we keep only what the DO needs:
// the spec, the SFU ingest identity for the roster, the adapter id to
// close, and the audit turn counter.
interface BotLeg {
  spec: BotSpec;
  ingestAdapterId: string | null;
  ingestSessionId: string | null;
  ingestTrackName: string | null;
  turnIndex: number;
}

interface HumanState {
  track: HumanTrack;
  // The SFU stream adapter the DO created for this human. Doubles as the
  // intent guard: a `stream-dropped` event recreates the adapter only while
  // this is non-null (a DO-initiated close nulls it first).
  adapterId: string | null;
  // Wall-clock ms of the last /control/heartbeat (or initial add-human).
  lastSeenAt: number;
}

export class RoomVoiceDO {
  private state: DurableObjectState;
  private env: Env;
  private ctx: RoomContext | null = null;

  private bots = new Map<string, BotLeg>();
  private humans = new Map<string, HumanState>();
  private pendingInvites = new Map<string, PendingInvite>();
  private callAdminIds = new Set<string>();

  // Control WebSocket to the media container. Opened on start; if it drops
  // mid-call the call ends (a container crash is a hard failure for v1 —
  // reconnect/resync is a follow-up once the happy path is validated).
  private mediaWs: WebSocket | null = null;
  private mediaOpening: Promise<void> | null = null;

  private joinGraceTimer: ReturnType<typeof setTimeout> | null = null;
  private presenceAuditTimer: ReturnType<typeof setTimeout> | null = null;
  private humanEverJoined = false;
  private closed = false;
  private cumulativePnd = 0;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case '/control/start':
        return this.start((await request.json()) as StartPayload);
      case '/control/add-bot':
        return this.addBot((await request.json()) as BotSpec);
      case '/control/remove-bot': {
        const { botId } = (await request.json()) as { botId: string };
        await this.removeBot(botId);
        return Response.json({ ok: true });
      }
      case '/control/add-human':
        return this.addHuman((await request.json()) as HumanTrack);
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
      case '/control/leave': {
        const { humanId } = (await request.json()) as { humanId: string };
        await this.removeHuman(humanId);
        return Response.json({ ok: true });
      }
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
    try {
      const stub = getContainer(this.env.ROOM_MEDIA, ctx.roomId);
      const resp = await stub.fetch(
        new Request('https://media/control', { headers: { Upgrade: 'websocket' } }),
      );
      const ws = resp.webSocket;
      if (!ws) {
        console.warn('[room-voice] media control upgrade failed', resp.status);
        return;
      }
      ws.accept();
      this.mediaWs = ws;
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
          this.onMediaClosed();
        }
      });
      ws.addEventListener('error', () => {
        if (this.mediaWs === ws) {
          this.mediaWs = null;
          this.onMediaClosed();
        }
      });
      // Arm the container: the adapter token it must see in ?t=, and the
      // OpenAI key (passed at runtime so it stays out of the image).
      this.sendMedia({
        t: 'start',
        token: ctx.adapterToken,
        openaiApiKey: this.env.OPENAI_API_KEY ?? '',
      });
    } catch (err) {
      console.warn('[room-voice] openMediaChannel failed', err);
    }
  }

  private sendMedia(cmd: ControlCommand): void {
    const ws = this.mediaWs;
    if (!ws) {
      console.warn('[room-voice] media channel not open, dropping', cmd.t);
      return;
    }
    try {
      ws.send(JSON.stringify(cmd));
    } catch {
      // socket gone — onMediaClosed will fire and end the call
    }
  }

  private onMediaClosed(): void {
    if (this.closed) return;
    console.warn('[room-voice] media channel closed unexpectedly; ending call');
    void this.finalize();
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
        return;
      case 'bot-tool':
        await this.handleBotTool(ev.botId, ev.name, ev.callId, ev.args);
        return;
      case 'turn-usage':
        await this.settleTurn(ev.botId, ev.usage);
        return;
      case 'leg-closed':
        await this.onLegClosed(ev.botId);
        return;
      case 'stream-dropped':
        this.handleStreamDropped(ev.humanId);
        return;
    }
  }

  // ── lifecycle ──────────────────────────────────────────────────────

  private async start(payload: StartPayload): Promise<Response> {
    if (this.ctx) return Response.json({ ok: true, already: true });
    const ctx: RoomContext = { ...payload.room, startedAt: Date.now() };
    this.ctx = ctx;
    await this.state.storage.put('ctx', ctx);

    // Open the media channel + arm the container before any bot joins.
    await this.ensureMedia();

    // Bring any prefilled bot up. The invite flow leaves this empty: bots
    // only join when a human taps "叫机器人来".
    for (const spec of payload.bots) {
      await this.connectBot(spec).catch((err) =>
        console.warn('[room-voice] bot leg failed at start', spec.botId, err),
      );
    }

    this.schedulePresenceAudit();
    this.joinGraceTimer = setTimeout(() => {
      if (!this.humanEverJoined) {
        console.warn('[room-voice] no human joined within grace window');
        void this.finalize();
      }
    }, JOIN_GRACE_MS);
    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    await this.upsertActiveIndex();
    await this.broadcastState('state');
    return Response.json({ ok: true, bots: [...this.bots.keys()] });
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
    this.bots.delete(botId);
    this.callAdminIds.delete(botId);
    // Tell the container to drop the bot's OpenAI + ingest sockets.
    this.sendMedia({ t: 'remove-bot', botId });
    if (leg.ingestAdapterId) {
      await closeAdapter(this.sfuApp(), leg.ingestAdapterId);
    }
    // A human-only call is fine — the room ends with its last human, not
    // its last bot (see removeHuman).
    await this.broadcastState('state');
  }

  // Bring up one bot: register it in the container (which opens its OpenAI
  // Realtime socket) and create the SFU ingest adapter that turns its voice
  // into a WebRTC track. The adapter's endpoint points at the container, so
  // the SFU dials the container (via the worker route) for this bot's PCM.
  private async connectBot(spec: BotSpec): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) throw new Error('room not started');

    const leg: BotLeg = {
      spec,
      ingestAdapterId: null,
      ingestSessionId: null,
      ingestTrackName: null,
      turnIndex: 0,
    };
    this.bots.set(spec.botId, leg);

    // Container leg first, so it exists when the SFU dials the ingest WS.
    await this.ensureMedia();
    this.sendMedia({ t: 'add-bot', spec: this.toContainerSpec(spec) });

    try {
      const ingest = await createIngestAdapter(this.sfuApp(), {
        trackName: `bot-${spec.botId}`,
        endpoint: this.adapterEndpoint(ctx, `ingest/${spec.botId}`),
      });
      leg.ingestAdapterId = ingest.adapterId;
      leg.ingestSessionId = ingest.sessionId ?? null;
      leg.ingestTrackName = ingest.trackName ?? `bot-${spec.botId}`;
    } catch (err) {
      console.warn('[room-voice] ingest adapter failed', spec.botId, err);
    }
  }

  // Translate the DO's BotSpec into the container's wire spec — flattening
  // the voice block and resolving the tool set (the DO owns permissions).
  private toContainerSpec(spec: BotSpec): ContainerBotSpec {
    return {
      botId: spec.botId,
      model: spec.model || DEFAULT_VOICE_MODEL_SLUG,
      instructions: spec.instructions,
      voice: spec.voiceConfig.voice || 'marin',
      turnDetection: spec.voiceConfig.turnDetection,
      tools: this.toolsFor(spec.botId),
    };
  }

  private roster(): {
    startedAt: number;
    initiatorId: string;
    bots: Array<{ botId: string; sfuSessionId: string; sfuTrackName: string }>;
    humans: Array<{ humanId: string; sfuSessionId: string; sfuTrackName: string }>;
    pending: Array<{ id: string; kind: 'human' | 'bot'; invitedAt: number; invitedBy: string }>;
  } {
    const bots: Array<{ botId: string; sfuSessionId: string; sfuTrackName: string }> = [];
    for (const leg of this.bots.values()) {
      if (leg.ingestSessionId && leg.ingestTrackName) {
        bots.push({
          botId: leg.spec.botId,
          sfuSessionId: leg.ingestSessionId,
          sfuTrackName: leg.ingestTrackName,
        });
      }
    }
    const humans: Array<{ humanId: string; sfuSessionId: string; sfuTrackName: string }> = [];
    for (const h of this.humans.values()) {
      humans.push({
        humanId: h.track.humanId,
        sfuSessionId: h.track.sfuSessionId,
        sfuTrackName: h.track.sfuTrackName,
      });
    }
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
    };
  }

  private async addHuman(track: HumanTrack): Promise<Response> {
    const ctx = this.ctx;
    if (!ctx) return new Response('room not started', { status: 400 });

    // Reconnect path: the human already has a HumanState but iOS minted a
    // NEW SFU session. Drop the old stream adapter and rebind. Clear
    // adapterId BEFORE closeAdapter so the resulting `stream-dropped` event
    // sees our side already nulled and skips the auto-recreate (we start a
    // fresh stream below ourselves).
    const existing = this.humans.get(track.humanId);
    if (existing) {
      const oldAdapter = existing.adapterId;
      existing.track = track;
      existing.adapterId = null;
      existing.lastSeenAt = Date.now();
      if (oldAdapter) {
        await closeAdapter(this.sfuApp(), oldAdapter).catch(() => {});
      }
      void this.connectHumanStream(track.humanId, ctx);
      const snapshot = this.roster();
      await this.broadcastState('state');
      return Response.json({ ok: true, rebound: true, ...snapshot });
    }

    const human: HumanState = {
      track,
      adapterId: null,
      lastSeenAt: Date.now(),
    };
    this.humans.set(track.humanId, human);
    this.pendingInvites.delete(track.humanId);
    this.humanEverJoined = true;
    if (this.joinGraceTimer) {
      clearTimeout(this.joinGraceTimer);
      this.joinGraceTimer = null;
    }

    // Bring the stream adapter up in the background with retries — iOS
    // connects ICE/DTLS a beat after it gets the SFU answer, so a one-shot
    // create loses the race with not_found_track_error.
    void this.connectHumanStream(track.humanId, ctx);

    const snapshot = this.roster();
    await this.broadcastState('state');
    return Response.json({ ok: true, ...snapshot });
  }

  private async connectHumanStream(humanId: string, ctx: RoomContext): Promise<void> {
    const maxAttempts = 12;
    const delayMs = 1500;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const human = this.humans.get(humanId);
      if (!human) return; // left before the adapter came up
      if (human.adapterId) return; // already connected
      try {
        const adapter = await createStreamAdapter(this.sfuApp(), {
          sessionId: human.track.sfuSessionId,
          trackName: human.track.sfuTrackName,
          endpoint: this.adapterEndpoint(ctx, `stream/${humanId}`),
        });
        human.adapterId = adapter.adapterId;
        return;
      } catch (err) {
        if (attempt === maxAttempts) {
          console.warn('[room-voice] stream adapter gave up', humanId, err);
          return;
        }
        await new Promise((r) => setTimeout(r, delayMs));
      }
    }
  }

  // The container reports a human's stream adapter socket closed. Recreate
  // it only if we still believe the human is live (adapterId set) — a
  // DO-initiated close (leave / rebind / finalize) nulls adapterId first.
  private handleStreamDropped(humanId: string): void {
    if (this.closed) return;
    const ctx = this.ctx;
    if (!ctx) return;
    const human = this.humans.get(humanId);
    if (!human || human.adapterId === null) return;
    human.adapterId = null;
    console.warn('[room-voice] stream adapter dropped, recreating', humanId);
    void this.connectHumanStream(humanId, ctx);
  }

  private async removeHuman(humanId: string): Promise<void> {
    const human = this.humans.get(humanId);
    if (!human) return;
    this.humans.delete(humanId);
    if (human.adapterId) {
      await closeAdapter(this.sfuApp(), human.adapterId);
    }
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
    this.callAdminIds.add(targetId);
    const leg = this.bots.get(targetId);
    if (leg) this.pushBotTools(leg);
    return Response.json({ ok: true });
  }

  private async broadcastState(event: 'state' | 'ended'): Promise<void> {
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
    };
    await publishToHub(this.env, `conv:${ctx.conversationId}`, payload).catch((err) =>
      console.warn('[room-voice] broadcast failed', err),
    );
  }

  private sfuApp(): SfuApp {
    return {
      appId: this.env.SFU_APP_ID ?? '',
      appSecret: this.env.SFU_APP_SECRET ?? '',
    };
  }

  private adapterEndpoint(ctx: RoomContext, slot: string): string {
    return (
      `${ctx.publicWsBase}${ctx.adapterPath}/${ctx.roomId}/${slot}` +
      `?t=${encodeURIComponent(ctx.adapterToken)}`
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

  // The container's media leg for a bot closed (its OpenAI socket died).
  // Drop the leg + close its ingest adapter. A bot leg dying doesn't end
  // the call — humans can still talk; the room ends with its last human.
  private async onLegClosed(botId: string): Promise<void> {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.bots.delete(botId);
    this.callAdminIds.delete(botId);
    if (leg.ingestAdapterId) {
      await closeAdapter(this.sfuApp(), leg.ingestAdapterId);
    }
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
        if (!targetId) {
          this.sendMedia({ t: 'tool-result', botId, callId, output: 'refused: missing target_id' });
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
    if (this.closed || !this.humanEverJoined) return;
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

  private async settleTurn(botId: string, usage: RealtimeUsage): Promise<void> {
    const ctx = this.ctx;
    if (!ctx || this.closed) return;
    const leg = this.bots.get(botId);
    if (!leg) return;

    const inDetails = usage.input_token_details;
    const cachedText = inDetails?.cached_tokens_details?.text_tokens ?? 0;
    const cachedAudio = inDetails?.cached_tokens_details?.audio_tokens ?? 0;
    const cacheReadTokens = inDetails?.cached_tokens ?? 0;
    const inputTokens = Math.max(0, (inDetails?.text_tokens ?? 0) - cachedText);
    const audioInputTokens = Math.max(0, (inDetails?.audio_tokens ?? 0) - cachedAudio);

    const supa = serviceClient(this.env);
    let route;
    try {
      route = await resolveRoute(supa, this.env, {
        modelSlug: leg.spec.model || DEFAULT_VOICE_MODEL_SLUG,
        preferProvider: 'openai',
        metadata: { userId: ctx.billUserId, conversationId: ctx.conversationId },
      });
    } catch (err) {
      console.warn('[room-voice] resolveRoute failed', err);
      return;
    }

    const turnUsage = {
      inputTokens,
      outputTokens: usage.output_token_details?.text_tokens ?? 0,
      audioInputTokens,
      audioOutputTokens: usage.output_token_details?.audio_tokens ?? 0,
      cacheReadTokens,
    } as const;

    await enqueueAudit(this.env, route, {
      userId: ctx.billUserId,
      conversationId: ctx.conversationId,
      taskType: 'voice_call',
      startedAt: Date.now(),
      status: 'success',
      ...turnUsage,
      metadata: {
        source: 'group_voice_call',
        room_id: ctx.roomId,
        turn_index: leg.turnIndex++,
        bot_id: leg.spec.botId,
      },
    });

    void this.broadcastCost(supa, route?.modelToCall, turnUsage);
  }

  private async broadcastCost(
    supa: ReturnType<typeof serviceClient>,
    modelToCall: string | undefined,
    usage: {
      inputTokens: number;
      outputTokens: number;
      audioInputTokens: number;
      audioOutputTokens: number;
      cacheReadTokens: number;
    },
  ): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;
    const usd = computeVoiceCost(modelToCall, usage);
    if (usd == null) return;
    try {
      const markup = await getMarkup(supa);
      const delta = usdToPnd(usd, markup);
      if (delta <= 0) return;
      this.cumulativePnd += delta;
      await publishToHub(this.env, `conv:${ctx.conversationId}`, {
        type: 'voice_cost',
        conversation_id: ctx.conversationId,
        session_id: ctx.roomId,
        delta_pnd: delta,
        cumulative_pnd: this.cumulativePnd,
        at_ms: Date.now(),
      });
    } catch (err) {
      console.warn('[room-voice] broadcast cost failed', err);
    }
  }

  // ── teardown ───────────────────────────────────────────────────────

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    // Notify the conv channel first — once we tear down the snapshot is
    // meaningless.
    await this.broadcastState('ended');
    await this.clearActiveIndex();
    if (this.joinGraceTimer) clearTimeout(this.joinGraceTimer);
    this.joinGraceTimer = null;
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

    const app = this.sfuApp();
    const adapterIds: Array<string | null> = [
      ...[...this.bots.values()].map((b) => b.ingestAdapterId),
      ...[...this.humans.values()].map((h) => h.adapterId),
    ];
    for (const id of adapterIds) {
      if (id) await closeAdapter(app, id);
    }

    this.bots.clear();
    this.humans.clear();
    this.pendingInvites.clear();

    await this.state.storage.deleteAlarm().catch(() => undefined);
    await this.state.storage.deleteAll().catch(() => undefined);
  }

  async alarm(): Promise<void> {
    await this.finalize();
  }
}
