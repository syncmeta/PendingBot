import puppeteer, { type Browser, type Page } from 'puppeteer-core';
import type { ServerWebSocket } from 'bun';
import { bytesToSamples, samplesToBytes } from './pcm';
import type { WsData } from './room';

const OPENAI_RATE = 24_000;

interface RealtimeKitBridgeOptions {
  botId: string;
  meetingId: string;
  participantId: string;
  authToken: string;
  roomToken: string;
  port: number;
  onInput: (samples: Int16Array) => void;
  onClosed: () => void;
}

interface BridgeMessage {
  t?: string;
  audio?: string;
  message?: string;
}

let browserPromise: Promise<Browser> | null = null;

async function browser(): Promise<Browser> {
  if (!browserPromise) {
    const executablePath = process.env.CHROMIUM_PATH ?? '/usr/bin/chromium';
    browserPromise = puppeteer.launch({
      executablePath,
      headless: true,
      args: [
        '--autoplay-policy=no-user-gesture-required',
        '--disable-dev-shm-usage',
        '--disable-gpu',
        '--no-sandbox',
        '--use-fake-ui-for-media-stream',
      ],
    });
  }
  return browserPromise;
}

function jsString(value: string): string {
  return JSON.stringify(value);
}

export class RealtimeKitBridge {
  private opts: RealtimeKitBridgeOptions;
  private page: Page | null = null;
  private ws: ServerWebSocket<WsData> | null = null;
  private closed = false;

  constructor(opts: RealtimeKitBridgeOptions) {
    this.opts = opts;
  }

  get connected(): boolean {
    return this.ws !== null;
  }

  async start(): Promise<void> {
    if (this.closed || this.page) return;
    const b = await browser();
    const page = await b.newPage();
    this.page = page;
    page.on('console', (msg) => {
      console.log(`[rtk-bridge ${this.opts.botId}] ${msg.type()} ${msg.text()}`);
    });
    page.on('pageerror', (err) => {
      console.warn(`[rtk-bridge ${this.opts.botId}] page error`, err);
    });
    await page.goto(this.pageUrl(), { waitUntil: 'domcontentloaded' });
  }

  html(): string {
    const authToken = jsString(this.opts.authToken);
    const meetingId = jsString(this.opts.meetingId);
    const participantId = jsString(this.opts.participantId);
    const wsUrl = jsString(this.wsUrl());
    return `<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body>
<script src="https://cdn.jsdelivr.net/npm/@cloudflare/realtimekit@1.4.0/dist/browser.js"></script>
<script>
const authToken = ${authToken};
const meetingId = ${meetingId};
const participantId = ${participantId};
const wsUrl = ${wsUrl};
const OPENAI_RATE = 24000;
let meeting;
let audioContext;
let destination;
let nextPlayAt = 0;
const wiredTracks = new WeakSet();
const watchedParticipants = new Set();

function log(message) {
  console.log(String(message));
  try { socket && socket.readyState === WebSocket.OPEN && socket.send(JSON.stringify({ t: 'log', message: String(message) })); } catch (_) {}
}

function b64ToI16(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Int16Array(bytes.buffer);
}

function i16ToB64(samples) {
  const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function playOutput(b64) {
  if (!audioContext || !destination) return;
  const samples = b64ToI16(b64);
  if (samples.length === 0) return;
  const buffer = audioContext.createBuffer(1, samples.length, OPENAI_RATE);
  const channel = buffer.getChannelData(0);
  for (let i = 0; i < samples.length; i++) channel[i] = samples[i] / 32768;
  const source = audioContext.createBufferSource();
  source.buffer = buffer;
  source.connect(destination);
  const now = audioContext.currentTime;
  if (nextPlayAt < now + 0.03) nextPlayAt = now + 0.03;
  source.start(nextPlayAt);
  nextPlayAt += buffer.duration;
}

function participantArray(map) {
  if (!map) return [];
  if (typeof map.toArray === 'function') return map.toArray();
  if (typeof map.values === 'function') return Array.from(map.values());
  return Object.values(map);
}

function isBotParticipant(participant) {
  const customId = String(
    participant.customParticipantId || participant.clientSpecificId || participant.userId || '',
  );
  return customId.startsWith('pendingbot:bot:');
}

function wireTrack(participant, track) {
  if (!participant || participant.id === participantId) return;
  if (isBotParticipant(participant)) return;
  if (!track || wiredTracks.has(track)) return;
  wiredTracks.add(track);
  const stream = new MediaStream([track]);
  const source = audioContext.createMediaStreamSource(stream);
  const processor = audioContext.createScriptProcessor(2048, 1, 1);
  processor.onaudioprocess = (event) => {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    const input = event.inputBuffer.getChannelData(0);
    const out = new Int16Array(input.length);
    for (let i = 0; i < input.length; i++) {
      const v = Math.max(-1, Math.min(1, input[i]));
      out[i] = v < 0 ? v * 32768 : v * 32767;
    }
    socket.send(JSON.stringify({ t: 'input', audio: i16ToB64(out), rate: audioContext.sampleRate }));
  };
  source.connect(processor);
  processor.connect(audioContext.destination);
  log('wired audio ' + participant.id);
}

async function watchParticipant(participant) {
  if (!participant || participant.id === participantId) return;
  if (isBotParticipant(participant)) return;
  if (!watchedParticipants.has(participant.id)) {
    watchedParticipants.add(participant.id);
    if (typeof participant.on === 'function') {
      participant.on('audioUpdate', ({ audioEnabled, audioTrack }) => {
        if (audioEnabled && audioTrack) wireTrack(participant, audioTrack);
      });
    }
    try {
      await meeting.participants.subscribe([participant.id], ['audio']);
    } catch (err) {
      log('subscribe failed ' + participant.id + ' ' + err);
    }
  }
  if (participant.audioTrack) wireTrack(participant, participant.audioTrack);
}

function wireAllParticipants() {
  for (const p of participantArray(meeting && meeting.participants && meeting.participants.joined)) {
    watchParticipant(p);
  }
  for (const p of participantArray(meeting && meeting.participants && meeting.participants.audioSubscribed)) {
    watchParticipant(p);
  }
}

const socket = new WebSocket(wsUrl);
socket.onmessage = (event) => {
  try {
    const msg = JSON.parse(event.data);
    if (msg.t === 'output') playOutput(msg.audio || '');
    if (msg.t === 'close') window.close();
  } catch (err) {
    log('bad bridge message ' + err);
  }
};
socket.onopen = async () => {
  try {
    audioContext = new AudioContext({ sampleRate: 48000 });
    destination = audioContext.createMediaStreamDestination();
    if (!window.RealtimeKitClient) throw new Error('RealtimeKitClient global missing');
    meeting = await RealtimeKitClient.init({ authToken, defaults: { audio: false, video: false } });
    await meeting.join();
    await meeting.self.enableAudio(destination.stream.getAudioTracks()[0]);
    meeting.participants.joined.on('participantJoined', wireAllParticipants);
    meeting.participants.joined.on('participantsUpdate', wireAllParticipants);
    meeting.participants.audioSubscribed.on('participantJoined', wireAllParticipants);
    meeting.participants.audioSubscribed.on('participantsUpdate', wireAllParticipants);
    wireAllParticipants();
    socket.send(JSON.stringify({ t: 'ready' }));
    log('joined ' + meetingId);
  } catch (err) {
    log(err && err.stack ? err.stack : err);
    socket.close();
  }
};
</script>
</body>
</html>`;
  }

  attach(ws: ServerWebSocket<WsData>): void {
    if (this.ws) {
      try {
        this.ws.close();
      } catch {
        // already closing
      }
    }
    this.ws = ws;
  }

  detach(ws: ServerWebSocket<WsData>): void {
    if (this.ws !== ws) return;
    this.ws = null;
    if (!this.closed) this.opts.onClosed();
  }

  onMessage(raw: string): void {
    let msg: BridgeMessage;
    try {
      msg = JSON.parse(raw) as BridgeMessage;
    } catch {
      return;
    }
    if (msg.t === 'input' && msg.audio) {
      this.opts.onInput(bytesToSamples(Buffer.from(msg.audio, 'base64')));
    } else if (msg.t === 'log' && msg.message) {
      console.log(`[rtk-bridge ${this.opts.botId}] ${msg.message}`);
    }
  }

  sendAudio(mono24: Int16Array): void {
    const ws = this.ws;
    if (!ws) return;
    try {
      ws.send(
        JSON.stringify({
          t: 'output',
          audio: Buffer.from(samplesToBytes(mono24)).toString('base64'),
          rate: OPENAI_RATE,
        }),
      );
    } catch {
      // bridge closed; detach will follow
    }
  }

  close(): void {
    this.closed = true;
    try {
      this.ws?.send(JSON.stringify({ t: 'close' }));
    } catch {
      // already closing
    }
    try {
      this.ws?.close();
    } catch {
      // already closing
    }
    void this.page?.close().catch(() => undefined);
    this.page = null;
    this.ws = null;
  }

  private pageUrl(): string {
    return `http://127.0.0.1:${this.opts.port}/rtk/bot-page/${encodeURIComponent(this.opts.botId)}?t=${encodeURIComponent(this.opts.roomToken)}`;
  }

  private wsUrl(): string {
    return `ws://127.0.0.1:${this.opts.port}/rtk/bot/${encodeURIComponent(this.opts.botId)}?t=${encodeURIComponent(this.opts.roomToken)}`;
  }
}
