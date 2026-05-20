import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute, enqueueAudit, computeVoiceCost } from '../llm/router';
import { getMarkup, usdToPnd } from '../lib/billing';
import { publishToHub, type VoiceCallEvent } from '../lib/realtime-publish';
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
  downsample48to24,
  newDownsampleState,
  type DownsampleState,
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

// Fixed window per flush: 100 ms of 48 kHz interleaved stereo = 9600
// samples. Keeping every flush exactly this wide is what stops the
// OpenAI input timeline from drifting when the SFU delivers bursty
// chunks (catchup after a network blip, or under-delivery during one).
// Surplus stays in `pending` for the next flush; shortfall is padded
// with silence so wall-clock alignment holds.
const TARGET_STEREO_PER_FLUSH = (SFU_RATE * 2 * FLUSH_MS) / 1000;
// And the matching 24 kHz mono length we send to OpenAI per flush.
const TARGET_OPENAI_SAMPLES_PER_FLUSH = (OPENAI_RATE * FLUSH_MS) / 1000;

// A voice room exists only for its humans. If nobody joins within this
// window after start, end the call. With the new invite flow the
// initiator joins immediately after /voice/start so this is mostly a
// defensive timer — it still trips if the iOS WebRTC negotiation never
// completes.
const JOIN_GRACE_MS = 90 * 1000;

// iOS posts /voice/heartbeat every PRESENCE_HEARTBEAT_MS while the call
// is up. The DO removes a human whose last heartbeat is older than
// PRESENCE_TIMEOUT_MS — once the last admin's gone the room finalizes,
// even if /voice/leave never reached us (app killed, network down,
// SFU stream-adapter close never fired).
const PRESENCE_TIMEOUT_MS = 30 * 1000;
const PRESENCE_AUDIT_MS = 5 * 1000;

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
  // Wall-clock ms when /control/start ran — surfaced via roster() so the
  // in-conv banner can render a live "talking for N:NN" timer.
  startedAt: number;
}

// A participant the call invited but who hasn't joined yet. Humans land
// here when /voice/ring fires (the route also dispatches the APNs push);
// they leave when /control/add-human runs or someone cancels the invite.
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
  /// Resolved per-bot voice + turn-detection block from lib/voice-config.
  /// `turnDetection` follows the OpenAI tri-state: undefined = omit (use
  /// OpenAI default semantic_vad); null = push-to-talk; object = explicit.
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
  // Anti-alias biquad state for the 48→24 kHz downsample. Persists
  // across flushes so chunk boundaries don't click.
  downsampleState: DownsampleState;
  // Wall-clock ms of the last /control/heartbeat (or initial add-human).
  // The presence audit times out humans whose iOS stopped pinging.
  lastSeenAt: number;
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
  // Group participants the call invited but who haven't joined yet.
  // Surfaced via roster() so the in-call UI can render a "ringing" group.
  private pendingInvites = new Map<string, PendingInvite>();
  // Participants designated call-admin during this call (user or bot ids).
  // The initiator + group owner/admins are privileged without being here.
  private callAdminIds = new Set<string>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private joinGraceTimer: ReturnType<typeof setTimeout> | null = null;
  private presenceAuditTimer: ReturnType<typeof setTimeout> | null = null;
  // Has any human ever joined this call? Until the first join we keep
  // the room alive on the grace timer; after it, an empty room ends.
  private humanEverJoined = false;
  private closed = false;
  /// Running PND total across every bot leg in the room. Mirrors what
  /// AUDIT_QUEUE → billing_debit will eventually settle; published as
  /// `voice_cost` on conv:<id> so the in-call UI shows live spend.
  private cumulativePnd = 0;

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

  // ── lifecycle ──────────────────────────────────────────────────────

  private async start(payload: StartPayload): Promise<Response> {
    if (this.ctx) return Response.json({ ok: true, already: true });
    const ctx: RoomContext = { ...payload.room, startedAt: Date.now() };
    this.ctx = ctx;
    await this.state.storage.put('ctx', ctx);

    // Bring any prefilled bot up — historically /voice/start auto-pulled
    // every group bot here. The new invite flow leaves this list empty:
    // bots only join when a human explicitly taps "叫机器人来".
    for (const spec of payload.bots) {
      await this.connectBot(spec).catch((err) =>
        console.warn('[room-voice] bot leg failed at start', spec.botId, err),
      );
    }

    this.scheduleFlush();
    this.schedulePresenceAudit();
    // Defensive timer — the initiator's /voice/join should land within
    // a few seconds. If their WebRTC negotiation stalls and no human
    // ever joins, tear the empty room down.
    this.joinGraceTimer = setTimeout(() => {
      if (!this.humanEverJoined) {
        console.warn('[room-voice] no human joined within grace window');
        void this.finalize();
      }
    }, JOIN_GRACE_MS);
    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    // Index this active call so the message list can show a phone-icon
    // badge on conv rows without waking us up. finalize() clears the row.
    await this.upsertActiveIndex();
    await this.broadcastState('state');
    return Response.json({ ok: true, bots: [...this.bots.keys()] });
  }

  // Upsert/delete a row in pendingbot.voice_active_calls so the read-side
  // (the iOS message list) can do one cheap query instead of polling
  // every conversation's DO.
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

  // Mark a group participant as invited. Humans land here when /voice/ring
  // fires (the route layer also dispatches the APNs push); bots can also
  // be staged here when a future "invite-bot" path wants to show a
  // ringing state. Idempotent — re-invite is a no-op.
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
    this.pendingInvites.set(targetId, {
      kind,
      invitedAt: Date.now(),
      invitedBy,
    });
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
    // A human-only call is fine — don't tear down just because the last
    // bot left. The room ends when its last human leaves (see removeHuman).
    await this.broadcastState('state');
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

  // Everything a joining human subscribes to in order to hear the room:
  //   bots    — each bot's SFU ingest session + track (omitted until the
  //             ingest adapter is up)
  //   humans  — each human's own published mic session + track, so peers
  //             hear each other (the subscriber filters out its own id)
  //   pending — group participants invited but not yet joined
  //   startedAt — wall-clock ms when /control/start ran; drives the
  //             in-conv banner's elapsed-time display
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
    const humans: Array<{
      humanId: string;
      sfuSessionId: string;
      sfuTrackName: string;
    }> = [];
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
      pending.push({
        id,
        kind: inv.kind,
        invitedAt: inv.invitedAt,
        invitedBy: inv.invitedBy,
      });
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

    // Reconnect path: the human already has a HumanState from a prior
    // join, but iOS has just minted a NEW SFU session (e.g. after a
    // /voice/network watchdog tore the previous attempt down). Drop the
    // old stream adapter and rebind to the new session/track so their
    // mic actually reaches the room and peers can subscribe to them.
    //
    // Important: clear adapterId BEFORE calling closeAdapter so that
    // when the adapter's close event fires it sees we already nulled
    // out our side and skips the auto-reconnect path (we'll start a
    // fresh stream below ourselves).
    const existing = this.humans.get(track.humanId);
    if (existing) {
      const oldAdapter = existing.adapterId;
      existing.track = track;
      existing.adapterId = null;
      existing.pending = [];
      existing.downsampleState = newDownsampleState();
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
      pending: [],
      downsampleState: newDownsampleState(),
      lastSeenAt: Date.now(),
    };
    this.humans.set(track.humanId, human);
    this.pendingInvites.delete(track.humanId);
    this.humanEverJoined = true;
    if (this.joinGraceTimer) {
      clearTimeout(this.joinGraceTimer);
      this.joinGraceTimer = null;
    }

    // Stream adapter: the SFU streams this human's mic track out to our
    // endpoint as PCM. The SFU rejects the adapter until the human's
    // WebRTC peer is connected and actually sending RTP — which only
    // happens a beat AFTER /join hands the SFU answer back to iOS. So
    // bring the adapter up in the background with retries rather than
    // blocking (and failing) the join here.
    void this.connectHumanStream(track.humanId, ctx);

    // Hand back the roster (bots + the other humans already in the room)
    // so the joining human can subscribe and hear everyone.
    const snapshot = this.roster();
    await this.broadcastState('state');
    return Response.json({ ok: true, ...snapshot });
  }

  // Bring up a human's Stream adapter, retrying until their WebRTC peer
  // is sending packets. iOS connects ICE/DTLS a couple of seconds after
  // it receives the SFU answer, so a one-shot create reliably loses the
  // race with `not_found_track_error`.
  private async connectHumanStream(humanId: string, ctx: RoomContext): Promise<void> {
    const maxAttempts = 12;
    const delayMs = 1500;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const human = this.humans.get(humanId);
      if (!human) return;          // left before the adapter came up
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
      return;
    }
    await this.broadcastState('state');
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

  // Emit a snapshot of the current call state to the conversation's
  // realtime hub. Conv-channel subscribers re-render the in-conv banner
  // and (if open) the in-call participant list off this.
  //
  // Best-effort: a publish failure must not affect the actual call, so
  // we await but swallow. Two emit moments:
  //   'state'  — membership / pending changed
  //   'ended'  — finalize() ran; banner should disappear
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
    await publishToHub(this.env, `conv:${ctx.conversationId}`, payload).catch(
      (err) => console.warn('[room-voice] broadcast failed', err),
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
    // The SFU adapter pushes PCM as binary frames. Without this they
    // arrive as Blob (no `.byteLength`), and `new Uint8Array(blob)`
    // silently yields empty data — the bot then hears pure silence.
    server.binaryType = 'arraybuffer';

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
      // The SFU stream adapter's WebSocket closing does NOT mean the
      // human left the room. It can fire on a transient blip between
      // SFU and edge, or when we tore the adapter down ourselves
      // (removeHuman / rebind / finalize all set adapterId to null
      // first). Only the "spontaneous SFU/network close" case wants a
      // reconnect — that's the one where adapterId is still set and
      // the room is still alive. Whether the human is actually still
      // present is the iOS heartbeat's job (see auditPresence) — a
      // human who really is gone shows up as missing heartbeats within
      // PRESENCE_TIMEOUT_MS regardless of what this socket does.
      server.addEventListener('close', () => {
        if (this.closed) return;
        const human = this.humans.get(id);
        if (!human || human.adapterId === null) return;
        const ctx = this.ctx;
        if (!ctx) return;
        human.adapterId = null;
        human.pending = [];
        human.downsampleState = newDownsampleState();
        console.warn(
          '[room-voice] stream adapter closed unexpectedly, reconnecting',
          id,
        );
        void this.connectHumanStream(id, ctx);
      });
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

  // Sweep humans whose iOS stopped heartbeating. The SFU stream-adapter
  // close used to be our "human left" signal but it both over- and
  // under-fires (spurious closes on network blips; never fires if the
  // adapter never came up or the SFU keeps the WS alive past the source
  // session). Heartbeat is the source of truth now.
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

  private flush(): void {
    if (this.bots.size === 0) return;

    // Each human: extract exactly TARGET_STEREO_PER_FLUSH samples (100 ms)
    // of 48 kHz stereo PCM and fold to anti-aliased 24 kHz mono. Surplus
    // stays in `pending` for next flush; shortfall is padded with silence.
    // The fixed window stops OpenAI's input timeline from drifting when
    // the SFU delivers bursty / under-delivered chunks.
    const humanStreams: Int16Array[] = [];
    for (const human of this.humans.values()) {
      let stereo =
        human.pending.length === 0 ? null : concatSamples(human.pending);
      if (stereo && stereo.length > TARGET_STEREO_PER_FLUSH) {
        // Have more than 100 ms — take the front slice, stash the rest.
        // Copy the leftover so it owns its buffer (subarray is a view).
        const head = stereo.subarray(0, TARGET_STEREO_PER_FLUSH);
        const tail = stereo.subarray(TARGET_STEREO_PER_FLUSH);
        human.pending = [new Int16Array(tail)];
        stereo = head;
      } else {
        human.pending = [];
      }
      if (!stereo || stereo.length === 0) continue;
      // Pad short windows to the full 100 ms so the downsample state
      // and timeline stay aligned with wall-clock cadence.
      let mono48: Int16Array;
      if (stereo.length < TARGET_STEREO_PER_FLUSH) {
        const padded = new Int16Array(TARGET_STEREO_PER_FLUSH);
        padded.set(stereo);
        mono48 = stereoToMono(padded);
      } else {
        mono48 = stereoToMono(stereo);
      }
      humanStreams.push(downsample48to24(mono48, human.downsampleState));
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
      // Always send a 100 ms frame, even pure silence. Two reasons:
      //   1. Keep the OpenAI WebSocket warm — long silent stretches
      //      otherwise risk NAT/load-balancer idle disconnects.
      //   2. Keep the input_audio_buffer timeline aligned with
      //      wall-clock so server VAD makes decisions on a consistent
      //      cadence rather than catching up after a quiet gap.
      let mixed: Int16Array;
      if (inputs.length === 0) {
        mixed = new Int16Array(TARGET_OPENAI_SAMPLES_PER_FLUSH);
      } else if (inputs.length === 1) {
        mixed = inputs[0];
      } else {
        mixed = mixPcm(inputs);
      }
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
    const td = leg.spec.voiceConfig.turnDetection;
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
            input: {
              format: { type: 'audio/pcm', rate: OPENAI_RATE },
              // undefined → omit (OpenAI default semantic_vad);
              // null → disable VAD entirely (push-to-talk);
              // object → apply as-is.
              ...(td !== undefined && { turn_detection: td }),
            },
            output: {
              format: { type: 'audio/pcm', rate: OPENAI_RATE },
              voice: leg.spec.voiceConfig.voice || 'marin',
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

  // A bot's OpenAI socket closed — drop just that leg. A bot leg dying
  // doesn't end the call (humans can still talk to each other); the room
  // ends with its last human, not its last bot.
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
    void this.broadcastState('state');
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

    // Live PND preview to every conv subscriber — group calls fan out
    // on the conversation channel, so every joined human sees the same
    // cumulative spend. Same pricing helpers the audit consumer will
    // use, so the preview matches the eventual debit within rounding.
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
    // Notify the conv channel first — once we tear down sockets and
    // clear ctx, the snapshot we'd produce is meaningless.
    await this.broadcastState('ended');
    await this.clearActiveIndex();
    if (this.flushTimer) clearTimeout(this.flushTimer);
    this.flushTimer = null;
    if (this.joinGraceTimer) clearTimeout(this.joinGraceTimer);
    this.joinGraceTimer = null;
    if (this.presenceAuditTimer) clearTimeout(this.presenceAuditTimer);
    this.presenceAuditTimer = null;

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
    this.pendingInvites.clear();

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
