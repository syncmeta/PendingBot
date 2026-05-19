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
// (keyed by conversation_id). It makes the bot a participant in a CF
// Realtime SFU room WITHOUT terminating any WebRTC itself:
//
//   humans (WebRTC) ─▶ SFU ─▶ per-human Stream adapter (Opus→PCM) ─┐
//                                                                  ▼
//        RoomVoiceDO: decode protobuf, mix N humans, 48k→24k,  ─▶ OpenAI
//        feed OpenAI Realtime; OpenAI audio 24k→48k, protobuf  ◀─ Realtime
//                                                                  │
//   humans ◀─ SFU ◀─ Ingest adapter (PCM→Opus) ◀────────────────────┘
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

// Mixer cadence. Every tick the DO drains whatever human PCM arrived,
// mixes it and appends it to OpenAI. ~100 ms keeps added latency low
// while batching enough samples to be worth a frame.
const FLUSH_MS = 100;

// Stay under the adapter's 32 KB-per-message limit when sending bot
// audio to the Ingest adapter (leave headroom for protobuf framing).
const MAX_INGEST_PAYLOAD = 28_000;

interface RoomContext {
  roomId: string;
  conversationId: string;
  botId: string;
  // Whose balance the voice tokens bill to (attribution policy is the
  // caller's — the DO just records audit rows against this user).
  billUserId: string;
  model: string;
  instructions: string;
  voice: string;
  // wss:// origin the SFU can dial back, e.g. "wss://api.pendingname.com".
  publicWsBase: string;
  // Route prefix on the edge worker that forwards adapter WS upgrades
  // into this DO, e.g. "/v1/realtime/room".
  adapterPath: string;
  // Shared secret echoed in the adapter endpoint URL so only the SFU
  // dialling our published endpoint is accepted.
  adapterToken: string;
}

interface HumanTrack {
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

  private openaiWs: WebSocket | null = null;
  // The Ingest adapter socket — the SFU dials it and we push bot PCM in.
  private ingestWs: WebSocket | null = null;
  private ingestAdapterId: string | null = null;

  private humans = new Map<string, HumanState>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private turnIndex = 0;
  private closed = false;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // The SFU dials adapter endpoints — /adapter/ingest or
    // /adapter/stream/<humanId>. The edge route forwards those upgrades.
    if (request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      return this.handleAdapterUpgrade(url);
    }

    switch (url.pathname) {
      case '/control/start':
        return this.start((await request.json()) as RoomContext);
      case '/control/add-human':
        return this.addHuman((await request.json()) as HumanTrack);
      case '/control/remove-human': {
        const { humanId } = (await request.json()) as { humanId: string };
        await this.removeHuman(humanId);
        return Response.json({ ok: true });
      }
      case '/control/stop':
        await this.finalize();
        return Response.json({ ok: true });
      default:
        return new Response('not found', { status: 404 });
    }
  }

  // ── lifecycle ──────────────────────────────────────────────────────

  private async start(ctx: RoomContext): Promise<Response> {
    if (this.ctx) return Response.json({ ok: true, already: true });
    this.ctx = ctx;
    await this.state.storage.put('ctx', ctx);

    try {
      await this.connectOpenAI(ctx);
    } catch (err) {
      console.warn('[room-voice] openai connect failed', err);
      await this.finalize();
      return new Response('openai connect failed', { status: 502 });
    }

    // Ingest adapter: the SFU pulls the bot's voice from our endpoint and
    // publishes it as one WebRTC track everyone in the room subscribes to.
    try {
      const ingest = await createIngestAdapter(this.sfuApp(), {
        trackName: `bot-${ctx.botId}`,
        endpoint: this.adapterEndpoint(ctx, 'ingest'),
      });
      this.ingestAdapterId = ingest.adapterId;
    } catch (err) {
      console.warn('[room-voice] ingest adapter failed', err);
    }

    this.scheduleFlush();
    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    return Response.json({ ok: true });
  }

  private async addHuman(track: HumanTrack): Promise<Response> {
    const ctx = this.ctx;
    if (!ctx) return new Response('room not started', { status: 400 });
    if (this.humans.has(track.humanId)) {
      return Response.json({ ok: true, already: true });
    }
    const human: HumanState = { track, adapterId: null, pending: [] };
    this.humans.set(track.humanId, human);

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
    return Response.json({ ok: true });
  }

  private async removeHuman(humanId: string): Promise<void> {
    const human = this.humans.get(humanId);
    if (!human) return;
    this.humans.delete(humanId);
    if (human.adapterId) {
      await closeAdapter(this.sfuApp(), human.adapterId);
    }
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

    // Path tail: ".../ingest" or ".../stream/<humanId>".
    const parts = url.pathname.split('/').filter(Boolean);
    const slot = parts[parts.length - 2] === 'stream' ? 'stream' : parts[parts.length - 1];

    if (slot === 'ingest') {
      this.ingestWs = server;
    } else if (parts[parts.length - 2] === 'stream') {
      const humanId = parts[parts.length - 1];
      server.addEventListener('message', (ev) => {
        this.onHumanFrame(humanId, ev.data);
      });
      server.addEventListener('close', () => this.removeHuman(humanId));
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

  // ── mixer: human PCM -> OpenAI ─────────────────────────────────────

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
    const openai = this.openaiWs;
    if (!openai || this.humans.size === 0) return;

    // Each human: drain buffered 48 kHz stereo PCM, fold to 24 kHz mono.
    const monoStreams: Int16Array[] = [];
    for (const human of this.humans.values()) {
      if (human.pending.length === 0) continue;
      const stereo = concatSamples(human.pending);
      human.pending = [];
      const mono48 = stereoToMono(stereo);
      monoStreams.push(resample(mono48, SFU_RATE, OPENAI_RATE));
    }
    if (monoStreams.length === 0) return;

    const mixed = mixPcm(monoStreams);
    if (mixed.length === 0) return;
    try {
      openai.send(
        JSON.stringify({
          type: 'input_audio_buffer.append',
          audio: bytesToBase64(samplesToBytes(mixed)),
        }),
      );
    } catch {
      // socket gone — finalize will run from its close handler
    }
  }

  // ── OpenAI Realtime leg ────────────────────────────────────────────

  private async connectOpenAI(ctx: RoomContext): Promise<void> {
    const key = this.env.OPENAI_API_KEY;
    if (!key) throw new Error('OPENAI_API_KEY not configured');

    const resp = await fetch(
      `https://api.openai.com/v1/realtime?model=${encodeURIComponent(ctx.model || DEFAULT_VOICE_MODEL_SLUG)}`,
      { headers: { Upgrade: 'websocket', Authorization: `Bearer ${key}` } },
    );
    const ws = resp.webSocket;
    if (!ws) throw new Error(`openai upgrade failed: ${resp.status}`);
    ws.accept();
    this.openaiWs = ws;

    ws.addEventListener('message', (ev) => {
      this.onOpenAIMessage(ev).catch((err) =>
        console.warn('[room-voice] openai message failed', err),
      );
    });
    ws.addEventListener('close', () => this.finalize().catch(() => undefined));
    ws.addEventListener('error', () => this.finalize().catch(() => undefined));

    // Bake the persona server-side — the bot never gets instructions from
    // a client. 24 kHz PCM both ways matches the mixer's output rate.
    ws.send(
      JSON.stringify({
        type: 'session.update',
        session: {
          type: 'realtime',
          instructions: ctx.instructions,
          output_modalities: ['audio'],
          audio: {
            input: { format: { type: 'audio/pcm', rate: OPENAI_RATE } },
            output: {
              format: { type: 'audio/pcm', rate: OPENAI_RATE },
              voice: ctx.voice || 'marin',
            },
          },
        },
      }),
    );
  }

  private async onOpenAIMessage(ev: MessageEvent): Promise<void> {
    if (typeof ev.data !== 'string') return;
    let msg: {
      type?: string;
      delta?: string;
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
      this.sendBotAudio(msg.delta);
      return;
    }

    if (msg.type === 'error') {
      console.warn('[room-voice] openai error', JSON.stringify(msg).slice(0, 400));
      return;
    }

    // One audit row per completed model turn, billed from OpenAI's own
    // usage numbers (the DO is on the path, so this can't be faked).
    if (msg.type === 'response.done' && msg.response?.usage) {
      await this.settleTurn(msg.response.usage);
    }
  }

  // Bot 24 kHz mono PCM -> 48 kHz stereo -> protobuf -> Ingest adapter.
  private sendBotAudio(deltaB64: string): void {
    const ingest = this.ingestWs;
    if (!ingest) return;
    const mono24 = bytesToSamples(base64ToBytes(deltaB64));
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

  private async settleTurn(usage: RealtimeUsage): Promise<void> {
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
        modelSlug: ctx.model || DEFAULT_VOICE_MODEL_SLUG,
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
        turn_index: this.turnIndex++,
        bot_id: ctx.botId,
      },
    });
  }

  // ── teardown ───────────────────────────────────────────────────────

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.flushTimer) clearTimeout(this.flushTimer);
    this.flushTimer = null;

    const app = this.sfuApp();
    const adapterIds = [
      this.ingestAdapterId,
      ...[...this.humans.values()].map((h) => h.adapterId),
    ];
    for (const id of adapterIds) {
      if (id) await closeAdapter(app, id);
    }
    this.humans.clear();

    for (const ws of [this.openaiWs, this.ingestWs]) {
      try {
        ws?.close();
      } catch {
        // already closing
      }
    }
    this.openaiWs = null;
    this.ingestWs = null;
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
