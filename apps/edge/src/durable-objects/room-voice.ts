import { getContainer } from '@cloudflare/containers';
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute, enqueueAudit } from '../llm/router';
import { publishToHub, type VoiceCallEvent } from '../lib/realtime-publish';
import {
  broadcastVoiceCostPreview,
  splitRealtimeUsage,
  type VoiceTurnUsage,
} from '../lib/voice-metering';
import { roomMediaToken } from './room-voice-context';
import type {
  ContainerBotSpec,
  ControlCommand,
  ControlEvent,
  MediaDiagnostics,
  RealtimeUsage,
} from './room-media-protocol';

// RoomVoiceDO — the group-voice control plane. One instance per group call
// (keyed by conversation_id). Humans and bots are Cloudflare RealtimeKit
// participants; the media container runs the bot's headless WebRTC client,
// OpenAI Realtime sockets, audio mixing and playout clock. The DO keeps
// lifecycle, permissions/roles, presence, roster, realtime broadcasts and
// billing.

// Hard wall-clock cap, mirrors RealtimeMeterDO / lib/realtime-sessions.ts.
const MAX_CALL_MS = 30 * 60 * 1000;
const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';

// iOS posts /control/heartbeat while the call is up. A human whose last
// heartbeat is older than PRESENCE_TIMEOUT_MS is swept; once the last admin
// is gone the room finalizes.
const PRESENCE_TIMEOUT_MS = 30 * 1000;
const PRESENCE_AUDIT_MS = 5 * 1000;

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
}

interface HumanState {
  humanId: string;
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

  private presenceAuditTimer: ReturnType<typeof setTimeout> | null = null;
  private humanEverJoined = false;
  private closed = false;
  private cumulativePnd = 0;
  private latestDiagnostics: MediaDiagnostics | null = null;

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
      // Arm the container: the RTK bridge token it must see in ?t=, and the
      // OpenAI key (passed at runtime so it stays out of the image).
      this.sendMedia({
        t: 'start',
        token: roomMediaToken(ctx),
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
    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
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
      this.humans.set(id, { humanId: id, lastSeenAt: this.humans.get(id)?.lastSeenAt ?? now });
    }
    for (const id of this.humans.keys()) {
      if (!active.has(id)) this.humans.delete(id);
    }
    this.humanEverJoined = this.humans.size > 0;
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
    };
    this.bots.set(spec.botId, leg);

    await this.ensureMedia();
    this.sendMedia({ t: 'add-bot', spec: this.toContainerSpec(spec) });
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

    const turnUsage = splitRealtimeUsage(usage);

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
        // Humans in the room at this turn. splitAndDebit bills the turn
        // per-head across them, so over the call each member's total tracks
        // how long they were in it ("按在场时长分摊") — and nobody pays for
        // turns before they joined or after they left.
        present_user_ids: [...this.humans.keys()],
      },
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
    this.cumulativePnd = await broadcastVoiceCostPreview({
      env: this.env,
      supa,
      conversationId: ctx.conversationId,
      sessionId: ctx.roomId,
      modelToCall,
      usage,
      cumulativePnd: this.cumulativePnd,
      logPrefix: '[room-voice]',
    });
  }

  // ── teardown ───────────────────────────────────────────────────────

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
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

  async alarm(): Promise<void> {
    await this.finalize();
  }
}
