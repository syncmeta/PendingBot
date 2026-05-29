// The media engine for one group-voice room. One container instance per
// room (keyed by conversation_id), so this is a process-level singleton.
//
//   humans + bots are Cloudflare RealtimeKit WebRTC participants.
//
//   per bot: RTK remote audio + every OTHER bot ───────────────▶ OpenAI
//            voice ◀── OpenAI Realtime ───────────────────────┘
//              │
//              ├─▶ playout buffer ─(steady 20ms clock)─▶ RTK participant
//              └─▶ inter-bot buffer ─(input mixer)─▶ other bots' ears
//
// Why this lives in a container and not the Durable Object: real-time
// audio needs a real OS process with reliable timers and threads. workerd
// isolates get descheduled between events and their timers drift, which
// shows up as choppy bot audio. Bun's setInterval here paces a steady
// output clock; a pre-roll cushion absorbs OpenAI's bursty deltas. That
// combination — steady clock + cushion — is the anti-stutter core.

import type { ServerWebSocket } from 'bun';
import type {
  ContainerBotSpec,
  ControlCommand,
  ControlEvent,
  MediaDiagnostics,
  RealtimeUsage,
} from './protocol';
import {
  bytesToSamples,
  samplesToBytes,
  mixPcm,
  downsample48to24,
  newDownsampleState,
  concatSamples,
  type DownsampleState,
} from './pcm';
import { RealtimeKitBridge } from './realtimekit-bridge';
import { closeRealtimeKitBrowser } from './browser-manager';

const DEFAULT_VOICE_MODEL_SLUG = 'gpt-realtime-2';
const REALTIME_MAX_OUTPUT_TOKENS = 512;

// Audio rates. RealtimeKit bridge audio is 48 kHz mono; OpenAI Realtime
// speaks 24 kHz mono.
const REALTIMEKIT_RATE = 48_000;
const OPENAI_RATE = 24_000;

// Input mixer cadence (RealtimeKit remote audio + inter-bot → each bot's OpenAI input).
// 40 ms is finer than the old in-DO 100 ms — cheap here, and lower input
// latency helps the bot's VAD react. A real timer makes the window stable.
const INPUT_FLUSH_MS = 40;
const INPUT_MONO48_PER_FLUSH = (REALTIMEKIT_RATE * INPUT_FLUSH_MS) / 1000; // 1920
const INPUT_OPENAI_SAMPLES = (OPENAI_RATE * INPUT_FLUSH_MS) / 1000; // 960
const OPENAI_INPUT_TAIL_FLUSHES = Math.ceil(800 / INPUT_FLUSH_MS);

// Bot voice playout cadence (OpenAI output → RealtimeKit). A steady 20 ms
// frame clock with a pre-roll cushion is what kills the choppiness.
const PLAYOUT_TICK_MS = 20;
const PLAYOUT_SAMPLES = (OPENAI_RATE * PLAYOUT_TICK_MS) / 1000; // 480 mono@24k
// RealtimeKit already gives us a real WebRTC participant and the browser
// bridge has its own WebAudio scheduler, so keep the queue tight.
const RTK_PREROLL_MS = 80;
const RTK_PREROLL_SAMPLES = (OPENAI_RATE * RTK_PREROLL_MS) / 1000; // 1920
// Cap the inter-bot buffer so a continuously-talking bot can't grow it
// without bound if another leg stalls. 2 s is plenty for "bots hear each
// other"; older audio is dropped.
const INTERBOT_CAP_SAMPLES = OPENAI_RATE * 2;
// In a live room stale bot speech is worse than clipped bot speech. RTK
// output can arrive faster than wall-clock audio, so bound queued speech to
// a short, conversational window.
const RTK_PLAYOUT_CAP_MS = 1_500;
const RTK_PLAYOUT_CAP_SAMPLES = (OPENAI_RATE * RTK_PLAYOUT_CAP_MS) / 1000;

// How often to emit per-bot playout diagnostics over the control channel.
const STATS_MS = 2_000;

export type WsData =
  | { kind: 'control' }
  | { kind: 'rtk-bot'; botId: string };

interface BotLeg {
  spec: ContainerBotSpec;
  openaiWs: WebSocket | null;
  // Set once we've sent session.update — gates input so we never append
  // audio before the session's format/persona is configured.
  sessionReady: boolean;
  rtkBridge: RealtimeKitBridge | null;
  // RealtimeKit participant audio arrives as 48 kHz mono from the bridge.
  rtkPending: Int16Array[];
  rtkDownsampleState: DownsampleState;
  rtkInputLevel: number;
  rtkInputFrames: number;
  rtkQuietFrames: number;
  // Bot voice for humans — drained by the steady playout clock (24k mono).
  playout: Int16Array[];
  playoutState: 'buffering' | 'playing';
  // Bot voice for the OTHER bots' ears — drained by the input mixer.
  interbot: Int16Array[];
  // Tail silence after real input lets OpenAI server VAD close the turn
  // without keeping a silent room streaming forever.
  inputTailFlushes: number;
  // Diagnostics for the current ~2s stats window (reset on emit).
  lastDeltaAt: number;
  maxGapMs: number;
  droppedOutputMs: number;
  underruns: number;
  voiceFrames: number;
  silenceFrames: number;
}

function totalLen(chunks: Int16Array[]): number {
  let n = 0;
  for (const c of chunks) n += c.length;
  return n;
}

// Drop oldest samples so a chunk list stays under `cap` total samples.
export function trimOldest(chunks: Int16Array[], cap: number): number {
  let over = totalLen(chunks) - cap;
  let dropped = 0;
  while (over > 0 && chunks.length > 0) {
    const head = chunks[0];
    if (head.length <= over) {
      over -= head.length;
      dropped += head.length;
      chunks.shift();
    } else {
      chunks[0] = new Int16Array(head.subarray(over));
      dropped += over;
      over = 0;
    }
  }
  return dropped;
}

// Take up to `n` samples off the front of a chunk list; return the taken
// slice and leave the remainder (as a single chunk) on the list ref.
function drainFront(
  chunks: Int16Array[],
  n: number,
): { taken: Int16Array; rest: Int16Array[] } {
  const all = concatSamples(chunks);
  if (all.length <= n) return { taken: all, rest: [] };
  return { taken: all.subarray(0, n), rest: [new Int16Array(all.subarray(n))] };
}

function rmsLevel(samples: Int16Array): number {
  if (samples.length === 0) return 0;
  let sum = 0;
  const stride = Math.max(1, Math.floor(samples.length / 2048));
  let count = 0;
  for (let i = 0; i < samples.length; i += stride) {
    const normalized = samples[i] / 32768;
    sum += normalized * normalized;
    count++;
  }
  return Math.sqrt(sum / Math.max(1, count));
}

export function realtimeKitPlayoutLimits(): {
  prerollSamples: number;
  capSamples: number;
} {
  return { prerollSamples: RTK_PREROLL_SAMPLES, capSamples: RTK_PLAYOUT_CAP_SAMPLES };
}

export class Room {
  private token: string | null = null;
  private openaiApiKey: string | null = null;
  private controlWs: ServerWebSocket<WsData> | null = null;

  private bots = new Map<string, BotLeg>();

  private inputTimer: ReturnType<typeof setInterval> | null = null;
  private playoutTimer: ReturnType<typeof setInterval> | null = null;
  private statsTimer: ReturnType<typeof setInterval> | null = null;
  private closed = false;
  private port = Number(process.env.PORT ?? 8080);

  // ── control plane (DO <-> container) ───────────────────────────────

  onControlOpen(ws: ServerWebSocket<WsData>): void {
    this.controlWs = ws;
    this.emit({ t: 'ready' });
  }

  onControlClose(ws: ServerWebSocket<WsData>): void {
    if (this.controlWs === ws) this.controlWs = null;
  }

  private emit(event: ControlEvent): void {
    const ws = this.controlWs;
    if (!ws) return;
    try {
      ws.send(JSON.stringify(event));
    } catch {
      // control socket gone — DO will reopen or end the room
    }
  }

  async onControlMessage(raw: string): Promise<void> {
    let cmd: ControlCommand;
    try {
      cmd = JSON.parse(raw) as ControlCommand;
    } catch {
      return;
    }
    switch (cmd.t) {
      case 'start':
        this.start(cmd.token, cmd.openaiApiKey);
        return;
      case 'add-bot':
        await this.addBot(cmd.spec);
        return;
      case 'remove-bot':
        this.removeBot(cmd.botId);
        return;
      case 'update-tools':
        this.updateTools(cmd.botId, cmd.tools);
        return;
      case 'tool-result':
        this.sendToolResult(cmd.botId, cmd.callId, cmd.output);
        return;
      case 'ping':
        // Heartbeat from the DO — reply so it knows the control link
        // (and this process) is alive.
        this.emit({ t: 'pong' });
        return;
      case 'end':
        this.end();
        return;
    }
  }

  /** True once the DO has armed the room — gates RTK page/WS auth. */
  isArmed(): boolean {
    return this.token !== null;
  }

  tokenMatches(t: string | null): boolean {
    return this.token !== null && t === this.token;
  }

  // Tear down all bot legs + media timers without ending the room or
  // touching the (live) control socket. Used by `start` to make a
  // resync replay idempotent on a reused warm instance. Unlike
  // `onLegClosed`/`removeBot`, this emits NO `leg-closed` events — the
  // DO is the one driving this reset and already knows the roster it is
  // about to rebuild.
  private resetForStart(): void {
    if (this.inputTimer) clearInterval(this.inputTimer);
    this.inputTimer = null;
    if (this.playoutTimer) clearInterval(this.playoutTimer);
    this.playoutTimer = null;
    if (this.statsTimer) clearInterval(this.statsTimer);
    this.statsTimer = null;
    for (const leg of this.bots.values()) {
      try {
        leg.openaiWs?.close();
      } catch {
        // already closing
      }
      leg.rtkBridge?.close();
    }
    this.bots.clear();
  }

  private start(token: string, openaiApiKey: string): void {
    // `start` is a RESET point. On a cold instance the room is already
    // empty and this is a no-op; on a warm/reused instance (the DO
    // reconnected after a control-socket drop and is replaying its
    // resync sequence) we must tear down stale legs + timers FIRST, so
    // the re-`add-bot` commands that follow rebuild cleanly without
    // double-running the input/playout/stats clocks or leaking the old
    // OpenAI + RealtimeKit sockets.
    this.resetForStart();
    this.token = token;
    this.openaiApiKey = openaiApiKey;
    this.closed = false;
    if (!this.inputTimer) {
      this.inputTimer = setInterval(() => this.inputFlush(), INPUT_FLUSH_MS);
    }
    if (!this.playoutTimer) {
      this.playoutTimer = setInterval(() => this.playoutTick(), PLAYOUT_TICK_MS);
    }
    if (!this.statsTimer) {
      this.statsTimer = setInterval(() => this.emitStats(), STATS_MS);
    }
  }

  // Periodic per-bot playout diagnostics. Logged container-side so they
  // land in the container's Cloudflare observability logs (dashboard) —
  // the DO's WebSocket-handler logs don't surface in `wrangler tail`, so
  // routing these through the control channel was invisible. Read these
  // when tuning choppiness: underruns>0 or large maxGap ⇒ upstream (OpenAI
  // delivery) is gappy; healthy depth + 0 underruns but still choppy ⇒
  // downstream (RTK browser/WebRTC). Reset the window counters after each.
  private emitStats(): void {
    if (this.closed) return;
    const diagnostics: MediaDiagnostics = { atMs: Date.now(), participants: [] };
    for (const [botId, leg] of this.bots) {
      const depthMs = Math.round(totalLen(leg.playout) / (OPENAI_RATE / 1000));
      console.log(
        `[room] stats bot=${botId} depth=${depthMs}ms state=${leg.playoutState} ` +
          `underruns=${leg.underruns} maxGap=${leg.maxGapMs}ms ` +
          `dropped=${leg.droppedOutputMs}ms ` +
          `voice=${leg.voiceFrames} silence=${leg.silenceFrames} ` +
          `rtkInput=${leg.rtkInputFrames} rtkQuiet=${leg.rtkQuietFrames} ` +
          `rtkLevel=${leg.rtkInputLevel.toFixed(3)}`,
      );
      diagnostics.participants.push({
        kind: 'bot',
        id: botId,
        speaking: leg.voiceFrames > 0 || depthMs > 0,
        audioLevel: leg.voiceFrames > 0 ? 1 : 0,
        source: 'model',
        playoutDepthMs: depthMs,
        underruns: leg.underruns,
        maxGapMs: leg.maxGapMs,
        droppedOutputMs: leg.droppedOutputMs,
        inputLevel: leg.rtkInputLevel,
        inputFrames: leg.rtkInputFrames,
        quietFrames: leg.rtkQuietFrames,
        realtimeKitConnected: Boolean(leg.rtkBridge?.connected),
        modelSessionReady: leg.sessionReady,
      });
      leg.underruns = 0;
      leg.maxGapMs = 0;
      leg.droppedOutputMs = 0;
      leg.voiceFrames = 0;
      leg.silenceFrames = 0;
      leg.rtkInputLevel = 0;
      leg.rtkInputFrames = 0;
      leg.rtkQuietFrames = 0;
    }
    this.emit({ t: 'diagnostics', diagnostics });
  }

  // ── bots ───────────────────────────────────────────────────────────

  private async addBot(spec: ContainerBotSpec): Promise<void> {
    if (this.bots.has(spec.botId)) return;
    const leg: BotLeg = {
      spec,
      openaiWs: null,
      sessionReady: false,
      rtkBridge: null,
      rtkPending: [],
      rtkDownsampleState: newDownsampleState(),
      rtkInputLevel: 0,
      rtkInputFrames: 0,
      rtkQuietFrames: 0,
      playout: [],
      playoutState: 'buffering',
      interbot: [],
      inputTailFlushes: 0,
      lastDeltaAt: 0,
      maxGapMs: 0,
      droppedOutputMs: 0,
      underruns: 0,
      voiceFrames: 0,
      silenceFrames: 0,
    };
    this.bots.set(spec.botId, leg);
    if (spec.realtimeKit) {
      leg.rtkBridge = new RealtimeKitBridge({
        botId: spec.botId,
        meetingId: spec.realtimeKit.meetingId,
        participantId: spec.realtimeKit.participantId,
        authToken: spec.realtimeKit.authToken,
        roomToken: this.token ?? '',
        port: this.port,
        onInput: (samples) => this.onRealtimeKitInput(spec.botId, samples),
        onQuietInput: (_rms, frames) => this.onRealtimeKitQuietInput(spec.botId, frames),
        onClosed: () => this.onRealtimeKitBridgeClosed(spec.botId),
      });
      void leg.rtkBridge.start().catch((err) =>
        console.warn('[room] realtimekit bridge failed', spec.botId, err),
      );
    }
    this.connectOpenAI(leg);
  }

  private removeBot(botId: string): void {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.bots.delete(botId);
    try {
      leg.openaiWs?.close();
    } catch {
      // already closing
    }
    leg.rtkBridge?.close();
  }

  realtimeKitBotPage(botId: string): Response {
    const bridge = this.bots.get(botId)?.rtkBridge;
    if (!bridge) return new Response('not found', { status: 404 });
    return new Response(bridge.html(), {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  attachRealtimeKitBot(botId: string, ws: ServerWebSocket<WsData>): boolean {
    const bridge = this.bots.get(botId)?.rtkBridge;
    if (!bridge) return false;
    bridge.attach(ws);
    return true;
  }

  detachRealtimeKitBot(botId: string, ws: ServerWebSocket<WsData>): void {
    this.bots.get(botId)?.rtkBridge?.detach(ws);
  }

  onRealtimeKitBridgeMessage(botId: string, message: string): void {
    this.bots.get(botId)?.rtkBridge?.onMessage(message);
  }

  private onRealtimeKitInput(botId: string, samples: Int16Array): void {
    const leg = this.bots.get(botId);
    if (!leg || samples.length === 0) return;
    leg.rtkInputLevel = Math.max(leg.rtkInputLevel, rmsLevel(samples));
    leg.rtkInputFrames++;
    leg.rtkPending.push(samples);
  }

  private onRealtimeKitQuietInput(botId: string, frames: number): void {
    const leg = this.bots.get(botId);
    if (!leg) return;
    leg.rtkQuietFrames += frames;
  }

  private onRealtimeKitBridgeClosed(botId: string): void {
    if (!this.closed) this.onLegClosed(botId);
  }

  private updateTools(botId: string, tools: unknown[]): void {
    const leg = this.bots.get(botId);
    const ws = leg?.openaiWs;
    if (!ws) return;
    leg!.spec.tools = tools;
    try {
      ws.send(
        JSON.stringify({
          type: 'session.update',
          session: { type: 'realtime', tools },
        }),
      );
    } catch {
      // socket gone — close handler fires onLegClosed
    }
  }

  // ── OpenAI Realtime leg ────────────────────────────────────────────

  private connectOpenAI(leg: BotLeg): void {
    const key = this.openaiApiKey;
    if (!key) {
      console.warn('[room] OPENAI key missing; cannot connect bot', leg.spec.botId);
      return;
    }
    const model = leg.spec.model || DEFAULT_VOICE_MODEL_SLUG;
    const ws = new WebSocket(
      `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`,
      { headers: { Authorization: `Bearer ${key}` } },
    );
    ws.binaryType = 'arraybuffer';
    leg.openaiWs = ws;

    ws.addEventListener('open', () => {
      const td = leg.spec.turnDetection;
      ws.send(
        JSON.stringify({
          type: 'session.update',
          session: {
            type: 'realtime',
            instructions: leg.spec.instructions,
            max_output_tokens: REALTIME_MAX_OUTPUT_TOKENS,
            output_modalities: ['audio'],
            tools: leg.spec.tools,
            tool_choice: 'auto',
            audio: {
              input: {
                format: { type: 'audio/pcm', rate: OPENAI_RATE },
                noise_reduction: { type: 'far_field' },
                // undefined → omit (OpenAI default server_vad);
                // null → disable VAD (push-to-talk); object → apply.
                ...(td !== undefined && { turn_detection: td }),
              },
              output: {
                format: { type: 'audio/pcm', rate: OPENAI_RATE },
                voice: leg.spec.voice || 'marin',
              },
            },
          },
        }),
      );
      leg.sessionReady = true;
    });
    ws.addEventListener('message', (ev: MessageEvent) => {
      this.onOpenAIMessage(leg, ev.data);
    });
    ws.addEventListener('close', () => this.onLegClosed(leg.spec.botId));
    ws.addEventListener('error', () => this.onLegClosed(leg.spec.botId));
  }

  private onOpenAIMessage(leg: BotLeg, data: unknown): void {
    if (typeof data !== 'string') return;
    let msg: {
      type?: string;
      delta?: string;
      name?: string;
      call_id?: string;
      arguments?: string;
      response?: { usage?: RealtimeUsage };
    };
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }

    if (
      (msg.type === 'response.output_audio.delta' ||
        msg.type === 'response.audio.delta') &&
      typeof msg.delta === 'string'
    ) {
      this.onBotAudio(leg, msg.delta);
      return;
    }

    if (
      msg.type === 'response.function_call_arguments.done' &&
      typeof msg.name === 'string'
    ) {
      // Forward to the DO — it owns permissions + roster. leave_call /
      // end_call / kick / designate are all decided there.
      this.emit({
        t: 'bot-tool',
        botId: leg.spec.botId,
        name: msg.name,
        callId: msg.call_id ?? '',
        args: msg.arguments,
      });
      return;
    }

    if (msg.type === 'error') {
      console.warn('[room] openai error', data.slice(0, 400));
      return;
    }

    if (msg.type === 'response.done' && msg.response?.usage) {
      this.emit({
        t: 'turn-usage',
        botId: leg.spec.botId,
        usage: msg.response.usage,
      });
    }
  }

  // Bot 24 kHz mono PCM delta: queue it for the steady playout clock (what
  // humans hear) and for the inter-bot mix (what other bots hear).
  private onBotAudio(leg: BotLeg, deltaB64: string): void {
    const mono24 = bytesToSamples(Buffer.from(deltaB64, 'base64'));
    if (mono24.length === 0) return;
    // Track inter-delta gap for diagnostics (largest gap this window).
    const now = Date.now();
    if (leg.lastDeltaAt > 0) {
      const gap = now - leg.lastDeltaAt;
      if (gap > leg.maxGapMs) leg.maxGapMs = gap;
    }
    leg.lastDeltaAt = now;
    leg.playout.push(mono24);
    leg.interbot.push(mono24);
    // Bound both buffers; drop oldest beyond the caps. Playout is capped
    // so stale speech does not lag behind the live RTK room; inter-bot is
    // capped in case a continuously-talking bot outruns another leg's drain.
    const cap = this.playoutCapSamples(leg);
    const dropped = trimOldest(leg.playout, cap);
    if (dropped > 0) {
      leg.droppedOutputMs += Math.round(dropped / (OPENAI_RATE / 1000));
      // After trimming stale audio, keep playing from the new head instead of
      // rebuilding a large cushion and adding more latency.
      leg.playoutState = 'playing';
    }
    trimOldest(leg.interbot, INTERBOT_CAP_SAMPLES);
  }

  // Result of a tool the DO executed (kick / designate) — hand it back so
  // the bot can acknowledge out loud.
  private sendToolResult(botId: string, callId: string, output: string): void {
    const ws = this.bots.get(botId)?.openaiWs;
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
      // socket gone — close handler fires onLegClosed
    }
  }

  private onLegClosed(botId: string): void {
    const leg = this.bots.get(botId);
    if (!leg) return;
    this.bots.delete(botId);
    leg.rtkBridge?.close();
    this.emit({ t: 'leg-closed', botId });
  }

  // ── input mixer: RealtimeKit + inter-bot -> each bot's OpenAI input ─

  private inputFlush(): void {
    if (this.closed || this.bots.size === 0) return;

    // Snapshot + drain each bot's inter-bot buffer so the others hear it
    // this tick. Snapshot first — a bot must hear the others but never
    // itself.
    const botAudio = new Map<string, Int16Array | null>();
    const botRealtimeKitAudio = new Map<string, Int16Array | null>();
    for (const [botId, leg] of this.bots) {
      if (leg.interbot.length === 0) {
        botAudio.set(botId, null);
      } else {
        const { taken, rest } = drainFront(leg.interbot, INPUT_OPENAI_SAMPLES);
        leg.interbot = rest;
        botAudio.set(botId, taken);
      }

      if (leg.rtkPending.length === 0) {
        botRealtimeKitAudio.set(botId, null);
      } else {
        const drained = drainFront(leg.rtkPending, INPUT_MONO48_PER_FLUSH);
        leg.rtkPending = drained.rest;
        const mono48 =
          drained.taken.length < INPUT_MONO48_PER_FLUSH
            ? (() => {
                const padded = new Int16Array(INPUT_MONO48_PER_FLUSH);
                padded.set(drained.taken);
                return padded;
              })()
            : drained.taken;
        botRealtimeKitAudio.set(
          botId,
          downsample48to24(mono48, leg.rtkDownsampleState),
        );
      }
    }

    for (const [botId, leg] of this.bots) {
      const ws = leg.openaiWs;
      if (!ws || !leg.sessionReady || ws.readyState !== WebSocket.OPEN) continue;
      const inputs: Int16Array[] = [];
      const rtkAudio = botRealtimeKitAudio.get(botId);
      if (rtkAudio && rtkAudio.length > 0) inputs.push(rtkAudio);
      for (const [otherId, audio] of botAudio) {
        if (otherId === botId || !audio || audio.length === 0) continue;
        inputs.push(audio);
      }
      let mixed: Int16Array;
      if (inputs.length === 0) {
        if (leg.inputTailFlushes <= 0) continue;
        leg.inputTailFlushes--;
        mixed = new Int16Array(INPUT_OPENAI_SAMPLES);
      } else {
        leg.inputTailFlushes = OPENAI_INPUT_TAIL_FLUSHES;
        mixed = inputs.length === 1 ? inputs[0] : mixPcm(inputs);
      }
      try {
        ws.send(
          JSON.stringify({
            type: 'input_audio_buffer.append',
            audio: Buffer.from(samplesToBytes(mixed)).toString('base64'),
          }),
        );
      } catch {
        // socket gone — close handler fires onLegClosed
      }
    }
  }

  // ── playout clock: bot voice -> RealtimeKit ───────────────────────

  private playoutTick(): void {
    if (this.closed) return;
    for (const leg of this.bots.values()) {
      const rtkBridge = leg.rtkBridge;
      if (!rtkBridge) continue;

      if (leg.playoutState === 'buffering') {
        if (totalLen(leg.playout) >= this.prerollSamples(leg)) {
          leg.playoutState = 'playing';
        } else {
          // Keep the RTK participant clock continuous while we build the
          // cushion.
          this.sendOutput(leg, new Int16Array(PLAYOUT_SAMPLES));
          leg.silenceFrames++;
          continue;
        }
      }

      const { taken, rest } = drainFront(leg.playout, PLAYOUT_SAMPLES);
      leg.playout = rest;
      let frame = taken;
      if (frame.length < PLAYOUT_SAMPLES) {
        const padded = new Int16Array(PLAYOUT_SAMPLES);
        padded.set(frame);
        frame = padded;
        leg.silenceFrames++;
        // Genuine underrun (cushion exhausted) — rebuild it before
        // resuming so a momentary OpenAI stall doesn't chop the speech.
        if (rest.length === 0) {
          leg.playoutState = 'buffering';
          leg.underruns++;
        }
      } else {
        leg.voiceFrames++;
      }
      this.sendOutput(leg, frame);
    }
  }

  private sendOutput(leg: BotLeg, mono24: Int16Array): void {
    leg.rtkBridge?.sendAudio(mono24);
  }

  private prerollSamples(leg: BotLeg): number {
    return realtimeKitPlayoutLimits().prerollSamples;
  }

  private playoutCapSamples(leg: BotLeg): number {
    return realtimeKitPlayoutLimits().capSamples;
  }

  // ── teardown ───────────────────────────────────────────────────────

  end(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.inputTimer) clearInterval(this.inputTimer);
    this.inputTimer = null;
    if (this.playoutTimer) clearInterval(this.playoutTimer);
    this.playoutTimer = null;
    if (this.statsTimer) clearInterval(this.statsTimer);
    this.statsTimer = null;
    for (const leg of this.bots.values()) {
      try {
        leg.openaiWs?.close();
      } catch {
        // already closing
      }
      leg.rtkBridge?.close();
    }
    this.bots.clear();
    void closeRealtimeKitBrowser();
    this.token = null;
    this.openaiApiKey = null;
  }
}
