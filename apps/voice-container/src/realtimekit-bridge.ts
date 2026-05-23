import type { Page } from 'puppeteer-core';
import type { ServerWebSocket } from 'bun';
import { newRealtimeKitPage } from './browser-manager';
import { bytesToSamples, samplesToBytes } from './pcm';
import type { WsData } from './room';

const OPENAI_RATE = 24_000;
const RTK_BROWSER_SDK_URL =
  'https://cdn.jsdelivr.net/npm/@cloudflare/realtimekit@1.4.0/dist/browser.js';
const RTK_INPUT_RMS_GATE = 0.008;
const RTK_INPUT_TAIL_FRAMES = 24;

interface RealtimeKitBridgeOptions {
  botId: string;
  meetingId: string;
  participantId: string;
  authToken: string;
  roomToken: string;
  port: number;
  onInput: (samples: Int16Array) => void;
  onQuietInput: (rms: number, frames: number) => void;
  onClosed: () => void;
}

interface BridgeMessage {
  t?: string;
  audio?: string;
  rms?: number;
  frames?: number;
  message?: string;
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
    const page = await newRealtimeKitPage();
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
    const botId = jsString(this.opts.botId);
    const participantId = jsString(this.opts.participantId);
    const wsUrl = jsString(this.wsUrl());
    return `<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body>
<script src="${RTK_BROWSER_SDK_URL}"></script>
<script>
const authToken = ${authToken};
const meetingId = ${meetingId};
const botId = ${botId};
const participantId = ${participantId};
const wsUrl = ${wsUrl};
const OPENAI_RATE = 24000;
const INPUT_RMS_GATE = ${RTK_INPUT_RMS_GATE};
const INPUT_TAIL_FRAMES = ${RTK_INPUT_TAIL_FRAMES};
let meeting;
let audioContext;
let destination;
let outputTrack;
let nextPlayAt = 0;
let inputFrames = 0;
let sentInputFrames = 0;
let suppressedInputFrames = 0;
let lastQuietReportFrame = 0;
let speechTailFrames = 0;
const wiredTracks = new WeakSet();
const watchedParticipants = new Set();
let manualSubscriptionUnavailable = false;
let manualSubscriptionNoticeLogged = false;

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

function participantIdentity(participant) {
  if (!participant || typeof participant !== 'object') return [];
  return [
    participant.id,
    participant.peerId,
    participant.peer_id,
    participant.userId,
    participant.user_id,
    participant.customParticipantId,
    participant.custom_participant_id,
    participant.clientSpecificId,
    participant.client_specific_id,
    participant.name,
    participant.displayName,
    participant.display_name,
  ].filter((v) => v !== undefined && v !== null).map((v) => String(v));
}

function participantSummary(participant) {
  return participantIdentity(participant).join('|') || 'unknown';
}

function isSelfParticipant(participant) {
  const values = participantIdentity(participant);
  if (values.includes(participantId)) return true;
  return values.some((v) => v.startsWith('pendingbot:bot:' + botId + ':'));
}

function isBotParticipant(participant) {
  return participantIdentity(participant).some((v) => v.startsWith('pendingbot:bot:'));
}

function rmsFloat(samples) {
  if (!samples || samples.length === 0) return 0;
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
  return Math.sqrt(sum / samples.length);
}

function sendInputFrame(input, rms) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  const out = new Int16Array(input.length);
  for (let i = 0; i < input.length; i++) {
    const v = Math.max(-1, Math.min(1, input[i]));
    out[i] = v < 0 ? v * 32768 : v * 32767;
  }
  socket.send(JSON.stringify({ t: 'input', audio: i16ToB64(out), rate: audioContext.sampleRate }));
  sentInputFrames++;
  if (sentInputFrames === 1 || sentInputFrames % 100 === 0) {
    log('input frames ' + sentInputFrames + ' rms ' + rms.toFixed(4));
  }
}

function maybeSendInput(input) {
  const rms = rmsFloat(input);
  if (rms >= INPUT_RMS_GATE) {
    speechTailFrames = INPUT_TAIL_FRAMES;
    sendInputFrame(input, rms);
    return;
  }
  if (speechTailFrames > 0) {
    speechTailFrames--;
    sendInputFrame(new Float32Array(input.length), 0);
    return;
  }
  suppressedInputFrames++;
  if (suppressedInputFrames === 1 || suppressedInputFrames % 250 === 0) {
    const frames = suppressedInputFrames - lastQuietReportFrame;
    lastQuietReportFrame = suppressedInputFrames;
    try {
      socket && socket.readyState === WebSocket.OPEN &&
        socket.send(JSON.stringify({ t: 'quiet', rms, frames }));
    } catch (_) {}
    log('suppressed quiet input frames ' + suppressedInputFrames + ' rms ' + rms.toFixed(4));
  }
}

function wireTrack(participant, track) {
  if (!participant || isSelfParticipant(participant)) return;
  if (isBotParticipant(participant)) {
    log('ignored bot participant audio ' + participantSummary(participant));
    return;
  }
  if (!track || wiredTracks.has(track)) return;
  if (outputTrack && (track === outputTrack || track.id === outputTrack.id)) {
    log('ignored local output audio track ' + participantSummary(participant));
    return;
  }
  wiredTracks.add(track);
  const stream = new MediaStream([track]);
  const source = audioContext.createMediaStreamSource(stream);
  const processor = audioContext.createScriptProcessor(2048, 1, 1);
  const silentSink = audioContext.createGain();
  silentSink.gain.value = 0;
  processor.onaudioprocess = (event) => {
    inputFrames++;
    maybeSendInput(event.inputBuffer.getChannelData(0));
  };
  source.connect(processor);
  processor.connect(silentSink);
  silentSink.connect(audioContext.destination);
  log('wired audio ' + participantSummary(participant));
}

function onParticipantAudioUpdate(participant, update) {
  const payload = update || {};
  const enabled = payload.audioEnabled !== undefined ? payload.audioEnabled : participant.audioEnabled;
  const track = payload.audioTrack || participant.audioTrack;
  if (enabled && track) wireTrack(participant, track);
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
    if (!manualSubscriptionUnavailable) {
      try {
        await meeting.participants.subscribe([participant.id], ['audio']);
      } catch (err) {
        if (String(err).includes('ERR1206')) {
          manualSubscriptionUnavailable = true;
          if (!manualSubscriptionNoticeLogged) {
            manualSubscriptionNoticeLogged = true;
            log('manual subscription unavailable; using auto audio');
          }
        } else {
          log('subscribe failed ' + participant.id + ' ' + err);
        }
      }
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
    outputTrack = destination.stream.getAudioTracks()[0];
    if (!window.RealtimeKitClient) throw new Error('RealtimeKitClient global missing');
    meeting = await RealtimeKitClient.init({ authToken, defaults: { audio: false, video: false } });
    await meeting.join();
    await meeting.self.enableAudio(outputTrack);
    meeting.participants.joined.on('participantJoined', wireAllParticipants);
    meeting.participants.joined.on('participantsUpdate', wireAllParticipants);
    meeting.participants.joined.on('audioUpdate', onParticipantAudioUpdate);
    if (meeting.participants.audioSubscribed) {
      meeting.participants.audioSubscribed.on('participantJoined', wireAllParticipants);
      meeting.participants.audioSubscribed.on('participantsUpdate', wireAllParticipants);
      meeting.participants.audioSubscribed.on('audioUpdate', onParticipantAudioUpdate);
    }
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
    } else if (msg.t === 'quiet' && typeof msg.rms === 'number') {
      this.opts.onQuietInput(msg.rms, Math.max(1, Math.round(msg.frames ?? 1)));
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
