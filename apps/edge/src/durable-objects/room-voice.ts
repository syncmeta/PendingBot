import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute, enqueueAudit } from '../llm/router';
import {
  createStreamAdapter,
  createIngestAdapter,
  closeAdapter,
  type SfuApp,
} from '../lib/sfu';
import { decodePacket, encodePayloadPacket } from '../lib/ws-adapter-proto';
import {
  bytesToSamples,
  samplesToBytes,
  stereoToMono,
  monoToStereo,
  resample,
  mixPcm,
} from '../lib/pcm';

// RoomVoiceDO — the group-voice bridge. One instance per group call
// (keyed by conversation_id). It puts one or more bots into a CF
// Realtime SFU room WITHOUT terminating any WebRTC itself:
//
//   humans (WebRTC) ─▶ SFU ─▶ per-human Stream adapter (Opus→PCM) ─┐
//                                                                  │
//   per-bot:  bot's ears = mix(all humans + every OTHER bot) ──────▶ OpenAI
//             bot's voice ◀── OpenAI Realtime ──────────────────────┘
//                  │
//                  ├─▶ per-bot Ingest adapter ─▶ SFU ─▶ humans hear it
//                  └─▶ buffered so the OTHER bots hear it too
//
// Each bot is a `BotLeg`: its own OpenAI Realtime socket and its own
// SFU Ingest adapter (so iOS gets one WebRTC track per bot and can tell
// who is speaking). Bots hear each other — a group call is treated like
// a room full of people, where everyone hears everyone. A bot never
// hears its own audio folded back (that would be echo / feedback).
//
// The SFU dials our WebSocket endpoints (the adapter `endpoint`), so the
// DO is purely a WebSocket server + PCM arithmetic — no WebRTC stack.
// See lib/sfu.ts, lib/pcm.ts, lib/ws-adapter-proto.ts.

// Hard wall-clock cap, mirrors RealtimeMeterDO / lib/realtime-sessions.ts.
const MAX_CALL_MS = 30 * 60 * 1000;
const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';

// Audio rates. The SFU WebSocket adapter is fixed at 48 kHz stereo;
// OpenAI Realtime speaks 24 kHz mono.
const SFU_RATE = 48_000;
const OPENAI_RATE = 24_000;

// Mixer cadence. Every tick the DO drains whatever human + bot PCM
// arrived, mixes it per bot and appends it to that bot's OpenAI socket.
// ~100 ms keeps added latency low while batching enough samples to be
// worth a frame.
const FLUSH_MS = 100;

// Stay under the adapter's 32 KB-per-message limit when sending bot
// audio to the Ingest adapter (leave headroom for protobuf framing).
const MAX_INGEST_PAYLOAD = 28_000;

// A voice room exists only for its humans. If nobody joins within this
// window after start, end the call — the bots have no one to talk to.
const JOIN_GRACE_MS = 90 * 1000;

// Room-level context — everything that is not per-bot.
interface RoomContext {
  roomId: string;
  conversationId: string;
  // Whose balance the voice tokens bill to. The control endpoint sets
  // this to the group creator, matching how group text turns attribute
  // cost today; M6's splitAndDebit will replace it with a real split.
  billUserId: string;
  // The user who started this call. Always privileged (can kick, end the
  // call, designate call-admins).
  initiatorUserId: string;
  // Group owner + admin user IDs (conversation_participants.role). Always
  // privileged for the lifetime of the call.
  groupAdminIds: string[];
  // wss:// origin the SFU can dial back, e.g. "wss://api.pendingname.com".
  publicWsBase: string;
  // Route prefix on the edge worker that forwards adapter WS upgrades
  // into this DO, e.g. "/v1/realtime-sfu".
  adapterPath: string;
  // Shared secret echoed in the adapter endpoint URL so only the SFU
  // dialling our published endpoint is accepted.
  adapterToken: string;
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

// Extra tools a bot gets only while it is a call-admin. A bot-admin has
// the same powers as a human admin — but the human-admin invariant still
// holds, so kicking the last human admin is refused.
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
  voice: string;
}

interface StartPayload {
  room: RoomContext;
  bots: BotSpec[];
}

interface HumanTrack {
  // The human's user id (conversation_participants.participant_id). Used
  // as the room key for this human AND for privilege checks.
  humanId: string;
  sfuSessionId: string;
  sfuTrackName: string;
}

// Usage block inside an OpenAI realtime `response.done` event.
interface RealtimeUsage {
  input_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
    cached_tokens?: number;
    cached_tokens_details?: { text_tokens?: number; audio_tokens?: number };
  };
  output_token_details?: { text_tokens?: number; audio_tokens?: number };
}

interface HumanState {
  track: HumanTrack;
  adapterId: string | null;
  // 48 kHz stereo PCM samples buffered since the last mixer flush.
  pending: Int16Array[];
}

interface BotLeg {
  spec: BotSpec;
  // OpenAI Realtime socket — this bot's ears + voice.
  openaiWs: WebSocket | null;
  // Ingest adapter socket the SFU dials to pull this bot's voice.
  ingestWs: WebSocket | null;
  ingestAdapterId: string | null;
  // The SFU session + track the ingest adapter created for this bot's
  // voice. Humans subscribe to these to hear the bot (see roster()).
  ingestSessionId: string | null;
  ingestTrackName: string | null;
  // The bot's own recent output (24 kHz mono), buffered between flushes
  // so the OTHER bots hear it on the next tick. Drained every flush.
  output: Int16Array[];
  // Per-bot audit turn counter.
  turnIndex: number;
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export class RoomVoiceDO {
  private state: DurableObjectState;
  private env: Env;
  private ctx: RoomContext | null = null;

  private bots = new Map<string, BotLeg>();
  private humans = new Map<string, HumanState>();
  // Participants designated call-admin during this call (user or bot ids).
  // The initiator + group owner/admins are privileged without being here.
  private callAdminIds = new Set<string>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private joinGraceTimer: ReturnType<typeof setTimeout> | null = null;
  // Has any human ever joined this call? Until the first join we keep
  // the room alive on the grace timer; after it, an empty room ends.
  private humanEverJoined = false;
  private closed = false;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // The SFU dials adapter endpoints — /ingest/<botId> or
    // /stream/<humanId>. The edge route forwards those upgrades.
    if (request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      return this.handleAdapterUpgrade(url);
    }

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
      case '/control/roster':
        return Response.json({ bots: this.roster() });
      case '/control/leave': {
        const { humanId } = (await request.json()) as { humanId: string };
        await this.removeHuman(humanId);
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

  // ── lifecycle ──────────────────────────────────────────────────────

  private async start(payload: StartPayload): Promise<Response> {
    if (this.ctx) return Response.json({ ok: true, already: true });
    if (payload.bots.length === 0) {
      return new Response('no bots', { status: 400 });
    }
    this.ctx = payload.room;
    await this.state.storage.put('ctx', payload.room);

    // Bring every bot's leg up. A leg that fails to connect is skipped;
    // the room only fails to start if NO bot came up.
    for (const spec of payload.bots) {
      await this.connectBot(spec).catch((err) =>
        console.warn('[room-voice] bot leg failed at start', spec.botId, err),
      );
    }
    if (this.bots.size === 0) {
      await this.finalize();
      return new Response('all bot legs failed', { status: 502 });
    }

    this.scheduleFlush();
    // End the call if no human has joined by the time the grace window
    // elapses — a bot-only room has nobody to talk to.
    this.joinGraceTimer = setTimeout(() => {
      if (!this.humanEverJoined) {
        console.warn('[room-voice] no human joined within grace window');
        void this.finalize();
      }
    }, JOIN_GRACE_MS);
    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    return Response.json({ ok: true, bots: [...this.bots.keys()] });
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
    return Response.json({ ok: true });
  }

  private async removeBot(botId: string): Promise<void> {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.bots.delete(botId);
    this.callAdminIds.delete(botId);
    try {
      leg.openaiWs?.close();
    } catch {
      // already closing
    }
    try {
      leg.ingestWs?.close();
    } catch {
      // already closing
    }
    if (leg.ingestAdapterId) {
      await closeAdapter(this.sfuApp(), leg.ingestAdapterId);
    }
    // A room with no bots left is pointless — tear the whole call down.
    if (this.bots.size === 0) await this.finalize();
  }

  // Bring up one bot: open its OpenAI Realtime socket and create the SFU
  // Ingest adapter that turns its voice into a WebRTC track.
  private async connectBot(spec: BotSpec): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) throw new Error('room not started');

    const leg: BotLeg = {
      spec,
      openaiWs: null,
      ingestWs: null,
      ingestAdapterId: null,
      ingestSessionId: null,
      ingestTrackName: null,
      output: [],
      turnIndex: 0,
    };
    await this.connectOpenAI(leg);
    this.bots.set(spec.botId, leg);

    // Ingest adapter: the SFU pulls this bot's voice from our endpoint
    // and publishes it as one WebRTC track everyone in the room hears.
    // The SFU generates a fresh session for the track; humans subscribe
    // to (ingestSessionId, ingestTrackName) to hear this bot.
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

  // The bots a human can subscribe to — each bot's SFU ingest session +
  // track. Bots whose ingest adapter hasn't come up yet are omitted.
  private roster(): Array<{
    botId: string;
    sfuSessionId: string;
    sfuTrackName: string;
  }> {
    const out: Array<{ botId: string; sfuSessionId: string; sfuTrackName: string }> = [];
    for (const leg of this.bots.values()) {
      if (leg.ingestSessionId && leg.ingestTrackName) {
        out.push({
          botId: leg.spec.botId,
          sfuSessionId: leg.ingestSessionId,
          sfuTrackName: leg.ingestTrackName,
        });
      }
    }
    return out;
  }

  private async addHuman(track: HumanTrack): Promise<Response> {
    const ctx = this.ctx;
    if (!ctx) return new Response('room not started', { status: 400 });
    if (this.humans.has(track.humanId)) {
      return Response.json({ ok: true, already: true });
    }
    const human: HumanState = { track, adapterId: null, pending: [] };
    this.humans.set(track.humanId, human);
    this.humanEverJoined = true;
    if (this.joinGraceTimer) {
      clearTimeout(this.joinGraceTimer);
      this.joinGraceTimer = null;
    }

    // Stream adapter: the SFU streams this human's mic track out to our
    // endpoint as PCM. The DO learns sfuSessionId / sfuTrackName from the
    // edge join route (the human published the track when they joined).
    try {
      const adapter = await createStreamAdapter(this.sfuApp(), {
        sessionId: track.sfuSessionId,
        trackName: track.sfuTrackName,
        endpoint: this.adapterEndpoint(ctx, `stream/${track.humanId}`),
      });
      human.adapterId = adapter.adapterId;
    } catch (err) {
      console.warn('[room-voice] stream adapter failed', track.humanId, err);
    }
    // Hand back the bot roster so the joining human can subscribe to
    // each bot's SFU track and hear them.
    return Response.json({ ok: true, bots: this.roster() });
  }

  private async removeHuman(humanId: string): Promise<void> {
    const human = this.humans.get(humanId);
    if (!human) return;
    this.humans.delete(humanId);
    if (human.adapterId) {
      await closeAdapter(this.sfuApp(), human.adapterId);
    }
    // A voice room must always have a human admin in it. Once none is
    // left — whether the room emptied out or the last human admin left
    // without designating a successor — the call ends.
    if (this.humanEverJoined && !this.humanAdminPresent()) {
      await this.finalize();
    }
  }

  // ── permissions & roster ───────────────────────────────────────────

  // The initiator, group owner/admins and designated call-admins are
  // privileged: they may kick, designate further admins, and end the
  // call. Works for human user ids and bot ids alike.
  private isPrivileged(actorId: string): boolean {
    const ctx = this.ctx;
    if (!ctx) return false;
    return (
      actorId === ctx.initiatorUserId ||
      ctx.groupAdminIds.includes(actorId) ||
      this.callAdminIds.has(actorId)
    );
  }

  // Is at least one privileged human still in the room? `exclude` lets a
  // kick check "would a human admin remain if I removed this one?".
  private humanAdminPresent(exclude?: string): boolean {
    for (const humanId of this.humans.keys()) {
      if (humanId === exclude) continue;
      if (this.isPrivileged(humanId)) return true;
    }
    return false;
  }

  // Kick a participant. Privileged actors only. Removing the last human
  // admin is refused — the room must always keep one (a voluntary leave
  // can still end the room, but a kick must not strand it).
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

  // Grant call-admin powers to a participant. Privileged actors only. If
  // the target is a bot in this call, push the admin tools to its session.
  private designateAdmin(actorId: string, targetId: string): Response {
    if (!this.isPrivileged(actorId)) {
      return new Response('forbidden', { status: 403 });
    }
    this.callAdminIds.add(targetId);
    const leg = this.bots.get(targetId);
    if (leg) this.updateBotTools(leg);
    return Response.json({ ok: true });
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

  // ── adapter sockets (SFU dials in) ─────────────────────────────────

  private handleAdapterUpgrade(url: URL): Response {
    const ctx = this.ctx;
    if (!ctx) return new Response('room not started', { status: 400 });
    if (url.searchParams.get('t') !== ctx.adapterToken) {
      return new Response('forbidden', { status: 403 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    // Path tail: ".../ingest/<botId>" or ".../stream/<humanId>".
    const parts = url.pathname.split('/').filter(Boolean);
    const kind = parts[parts.length - 2];
    const id = parts[parts.length - 1];

    if (kind === 'ingest') {
      const leg = this.bots.get(id);
      if (!leg) return new Response('unknown bot', { status: 404 });
      leg.ingestWs = server;
      server.addEventListener('close', () => {
        if (leg.ingestWs === server) leg.ingestWs = null;
      });
    } else if (kind === 'stream') {
      server.addEventListener('message', (ev) => {
        this.onHumanFrame(id, ev.data);
      });
      server.addEventListener('close', () => this.removeHuman(id));
    } else {
      return new Response('bad adapter slot', { status: 400 });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private onHumanFrame(humanId: string, data: string | ArrayBuffer): void {
    const human = this.humans.get(humanId);
    if (!human || typeof data === 'string') return;
    const packet = decodePacket(new Uint8Array(data));
    if (packet.payload.length === 0) return;
    human.pending.push(bytesToSamples(packet.payload));
  }

  // ── mixer: humans + bots -> each bot's OpenAI socket ───────────────

  private scheduleFlush(): void {
    if (this.closed) return;
    this.flushTimer = setTimeout(() => {
      try {
        this.flush();
      } catch (err) {
        console.warn('[room-voice] flush failed', err);
      }
      this.scheduleFlush();
    }, FLUSH_MS);
  }

  private flush(): void {
    if (this.bots.size === 0) return;

    // Each human: drain buffered 48 kHz stereo PCM, fold to 24 kHz mono.
    const humanStreams: Int16Array[] = [];
    for (const human of this.humans.values()) {
      if (human.pending.length === 0) continue;
      const stereo = concatSamples(human.pending);
      human.pending = [];
      const mono48 = stereoToMono(stereo);
      humanStreams.push(resample(mono48, SFU_RATE, OPENAI_RATE));
    }
    const humanMix = humanStreams.length > 0 ? mixPcm(humanStreams) : null;

    // Snapshot + drain each bot's own output buffer so the other bots
    // can hear it this tick. Snapshot first, then build inputs — a bot
    // must see the others' audio but never its own.
    const botAudio = new Map<string, Int16Array | null>();
    for (const [botId, leg] of this.bots) {
      if (leg.output.length === 0) {
        botAudio.set(botId, null);
        continue;
      }
      botAudio.set(botId, concatSamples(leg.output));
      leg.output = [];
    }

    for (const [botId, leg] of this.bots) {
      const openai = leg.openaiWs;
      if (!openai) continue;
      const inputs: Int16Array[] = [];
      if (humanMix && humanMix.length > 0) inputs.push(humanMix);
      for (const [otherId, audio] of botAudio) {
        if (otherId === botId || !audio || audio.length === 0) continue;
        inputs.push(audio);
      }
      if (inputs.length === 0) continue;

      const mixed = inputs.length === 1 ? inputs[0] : mixPcm(inputs);
      if (mixed.length === 0) continue;
      try {
        openai.send(
          JSON.stringify({
            type: 'input_audio_buffer.append',
            audio: bytesToBase64(samplesToBytes(mixed)),
          }),
        );
      } catch {
        // socket gone — its close handler runs onLegClosed
      }
    }
  }

  // ── OpenAI Realtime leg ────────────────────────────────────────────

  private async connectOpenAI(leg: BotLeg): Promise<void> {
    const key = this.env.OPENAI_API_KEY;
    if (!key) throw new Error('OPENAI_API_KEY not configured');

    const model = leg.spec.model || DEFAULT_VOICE_MODEL_SLUG;
    const resp = await fetch(
      `https://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`,
      { headers: { Upgrade: 'websocket', Authorization: `Bearer ${key}` } },
    );
    const ws = resp.webSocket;
    if (!ws) throw new Error(`openai upgrade failed: ${resp.status}`);
    ws.accept();
    leg.openaiWs = ws;

    ws.addEventListener('message', (ev) => {
      this.onOpenAIMessage(leg, ev).catch((err) =>
        console.warn('[room-voice] openai message failed', err),
      );
    });
    ws.addEventListener('close', () => this.onLegClosed(leg.spec.botId));
    ws.addEventListener('error', () => this.onLegClosed(leg.spec.botId));

    // Bake the persona server-side — the bot never gets instructions from
    // a client. 24 kHz PCM both ways matches the mixer's output rate.
    ws.send(
      JSON.stringify({
        type: 'session.update',
        session: {
          type: 'realtime',
          instructions: leg.spec.instructions,
          output_modalities: ['audio'],
          tools: this.toolsFor(leg.spec.botId),
          tool_choice: 'auto',
          audio: {
            input: { format: { type: 'audio/pcm', rate: OPENAI_RATE } },
            output: {
              format: { type: 'audio/pcm', rate: OPENAI_RATE },
              voice: leg.spec.voice || 'marin',
            },
          },
        },
      }),
    );
  }

  // The tool set a bot's realtime session should expose. Every bot can
  // hang itself up; a bot that is a call-admin also gets the admin tools.
  private toolsFor(botId: string): unknown[] {
    return this.isPrivileged(botId)
      ? [...BASE_BOT_TOOLS, ...ADMIN_BOT_TOOLS]
      : [...BASE_BOT_TOOLS];
  }

  // Re-push a bot's tool set — used when it is designated call-admin
  // mid-call and should gain the admin tools.
  private updateBotTools(leg: BotLeg): void {
    const ws = leg.openaiWs;
    if (!ws) return;
    try {
      ws.send(
        JSON.stringify({
          type: 'session.update',
          session: { type: 'realtime', tools: this.toolsFor(leg.spec.botId) },
        }),
      );
    } catch {
      // socket gone — its close handler runs onLegClosed
    }
  }

  // A bot's OpenAI socket closed — drop just that leg. If it was the
  // last bot, the room has nothing left to do, so finalize.
  private onLegClosed(botId: string): void {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.bots.delete(botId);
    this.callAdminIds.delete(botId);
    try {
      leg.ingestWs?.close();
    } catch {
      // already closing
    }
    if (leg.ingestAdapterId) {
      void closeAdapter(this.sfuApp(), leg.ingestAdapterId);
    }
    if (this.bots.size === 0) void this.finalize();
  }

  private async onOpenAIMessage(leg: BotLeg, ev: MessageEvent): Promise<void> {
    if (typeof ev.data !== 'string') return;
    let msg: {
      type?: string;
      delta?: string;
      name?: string;
      call_id?: string;
      arguments?: string;
      response?: { usage?: RealtimeUsage };
    };
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }

    // Bot audio out. The GA event is response.output_audio.delta; accept
    // the older response.audio.delta name defensively too.
    if (
      (msg.type === 'response.output_audio.delta' ||
        msg.type === 'response.audio.delta') &&
      typeof msg.delta === 'string'
    ) {
      this.onBotAudio(leg, msg.delta);
      return;
    }

    // The bot invoked a function tool. The GA event carrying the final
    // arguments is response.function_call_arguments.done — name / call_id
    // / arguments sit on it. (Unverified against a live session; the wire
    // detail is on the real-device checklist.)
    if (
      msg.type === 'response.function_call_arguments.done' &&
      typeof msg.name === 'string'
    ) {
      await this.handleBotTool(leg, msg.name, msg.call_id ?? '', msg.arguments);
      return;
    }

    if (msg.type === 'error') {
      console.warn('[room-voice] openai error', JSON.stringify(msg).slice(0, 400));
      return;
    }

    // One audit row per completed model turn, billed from OpenAI's own
    // usage numbers (the DO is on the path, so this can't be faked).
    if (msg.type === 'response.done' && msg.response?.usage) {
      await this.settleTurn(leg, msg.response.usage);
    }
  }

  // Bot 24 kHz mono PCM delta: push it to the SFU (humans hear it) and
  // buffer it so the other bots hear it on the next mixer tick.
  private onBotAudio(leg: BotLeg, deltaB64: string): void {
    const mono24 = bytesToSamples(base64ToBytes(deltaB64));
    leg.output.push(mono24);

    const ingest = leg.ingestWs;
    if (!ingest) return;
    const stereo48 = monoToStereo(resample(mono24, OPENAI_RATE, SFU_RATE));
    const bytes = samplesToBytes(stereo48);
    for (let off = 0; off < bytes.length; off += MAX_INGEST_PAYLOAD) {
      try {
        ingest.send(encodePayloadPacket(bytes.subarray(off, off + MAX_INGEST_PAYLOAD)));
      } catch {
        return;
      }
    }
  }

  // Execute a tool the bot invoked. `leave_call` / `end_call` tear the
  // bot (or room) down, so they don't send a tool result — the socket is
  // gone. The others reply with a function_call_output so the bot can
  // acknowledge verbally.
  private async handleBotTool(
    leg: BotLeg,
    name: string,
    callId: string,
    argsJson: string | undefined,
  ): Promise<void> {
    const botId = leg.spec.botId;
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
      this.sendToolResult(leg, callId, 'refused: you are not a call-admin');
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
        this.sendToolResult(
          leg,
          callId,
          resp.ok ? 'ok' : `refused: ${await resp.text()}`,
        );
        return;
      }
      case 'designate_admin': {
        const targetId = typeof args.target_id === 'string' ? args.target_id : '';
        if (!targetId) {
          this.sendToolResult(leg, callId, 'refused: missing target_id');
          return;
        }
        this.callAdminIds.add(targetId);
        const targetLeg = this.bots.get(targetId);
        if (targetLeg) this.updateBotTools(targetLeg);
        this.sendToolResult(leg, callId, 'ok');
        return;
      }
      default:
        this.sendToolResult(leg, callId, `refused: unknown tool ${name}`);
    }
  }

  // Hand a tool's result back to the bot's realtime session and ask it
  // for a follow-up response so it can acknowledge the action out loud.
  private sendToolResult(leg: BotLeg, callId: string, output: string): void {
    const ws = leg.openaiWs;
    if (!ws || !callId) return;
    try {
      ws.send(
        JSON.stringify({
          type: 'conversation.item.create',
          item: { type: 'function_call_output', call_id: callId, output },
        }),
      );
      ws.send(JSON.stringify({ type: 'response.create' }));
    } catch {
      // socket gone — its close handler runs onLegClosed
    }
  }

  private async settleTurn(leg: BotLeg, usage: RealtimeUsage): Promise<void> {
    const ctx = this.ctx;
    if (!ctx || this.closed) return;

    const inDetails = usage.input_token_details;
    const cachedText = inDetails?.cached_tokens_details?.text_tokens ?? 0;
    const cachedAudio = inDetails?.cached_tokens_details?.audio_tokens ?? 0;
    const cacheReadTokens = inDetails?.cached_tokens ?? 0;
    const inputTokens = Math.max(0, (inDetails?.text_tokens ?? 0) - cachedText);
    const audioInputTokens = Math.max(
      0,
      (inDetails?.audio_tokens ?? 0) - cachedAudio,
    );

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

    await enqueueAudit(this.env, route, {
      userId: ctx.billUserId,
      conversationId: ctx.conversationId,
      taskType: 'voice_call',
      startedAt: Date.now(),
      status: 'success',
      inputTokens,
      outputTokens: usage.output_token_details?.text_tokens ?? 0,
      audioInputTokens,
      audioOutputTokens: usage.output_token_details?.audio_tokens ?? 0,
      cacheReadTokens,
      metadata: {
        source: 'group_voice_call',
        room_id: ctx.roomId,
        turn_index: leg.turnIndex++,
        bot_id: leg.spec.botId,
      },
    });
  }

  // ── teardown ───────────────────────────────────────────────────────

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.flushTimer) clearTimeout(this.flushTimer);
    this.flushTimer = null;
    if (this.joinGraceTimer) clearTimeout(this.joinGraceTimer);
    this.joinGraceTimer = null;

    const app = this.sfuApp();
    const adapterIds: Array<string | null> = [
      ...[...this.bots.values()].map((b) => b.ingestAdapterId),
      ...[...this.humans.values()].map((h) => h.adapterId),
    ];
    for (const id of adapterIds) {
      if (id) await closeAdapter(app, id);
    }

    for (const leg of this.bots.values()) {
      for (const ws of [leg.openaiWs, leg.ingestWs]) {
        try {
          ws?.close();
        } catch {
          // already closing
        }
      }
    }
    this.bots.clear();
    this.humans.clear();

    await this.state.storage.deleteAlarm().catch(() => undefined);
    await this.state.storage.deleteAll().catch(() => undefined);
  }

  async alarm(): Promise<void> {
    await this.finalize();
  }
}

/** Concatenate a list of PCM sample chunks into one buffer. */
function concatSamples(chunks: Int16Array[]): Int16Array {
  if (chunks.length === 1) return chunks[0];
  let len = 0;
  for (const c of chunks) len += c.length;
  const out = new Int16Array(len);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}
