import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute, enqueueAudit } from '../llm/router';
import { getBalance, getConfigInt } from '../lib/billing';
import { endRealtimeSession } from '../lib/realtime-sessions';

// RealtimeMeterDO — server-side, tamper-proof metering for a voice call.
//
// One instance per realtime session (keyed by session_id). It meters a
// voice call from OpenAI's authoritative `response.done` events so the
// client can't under-report usage to dodge billing. Two transports:
//
//   sideband (WebRTC) — audio is a direct iOS<->OpenAI WebRTC link
//     (best mobile latency). The worker isn't on that path, so the DO
//     opens a SECOND, control-only connection to the same call via its
//     call_id: GET wss://api.openai.com/v1/realtime?call_id=<id>. It
//     receives the same response.done events without touching audio.
//
//   proxy (WebSocket) — audio is JSON-framed over a WebSocket. iOS
//     connects to the worker (Supabase-JWT auth, no provider/CF
//     credential ever reaches the device); this DO bridges that socket
//     to OpenAI's realtime WebSocket and relays every frame. Because
//     the DO is on the path it meters directly, and because the hop is
//     iOS->Cloudflare->OpenAI it also works from regions where a direct
//     OpenAI connection is geo-blocked.
//
// Either way usage is read server-side and settled through the normal
// audit/billing path; the DO can also end the call on balance
// exhaustion or the 30-minute cap.

// Hard wall-clock cap, mirrors REALTIME_SESSION_MAX_AGE_MS in
// lib/realtime-sessions.ts.
const MAX_CALL_MS = 30 * 60 * 1000;

// Canonical voice model slug — resolveRoute keys task_routing_rules and
// the alias price lookup off this (same value as routes/realtime.ts).
const OPENAI_MODEL_SLUG = 'gpt-realtime';

type Transport = 'sideband' | 'proxy';

interface MeterContext {
  transport: Transport;
  sessionId: string;
  userId: string;
  conversationId: string;
  botId: string;
  startedAt: number;
  // sideband (WebRTC) only — the call_id from POST /v1/realtime/calls.
  callId?: string;
  // proxy (WebSocket) only — model id + baked persona for session.update.
  model?: string;
  instructions?: string;
}

// Usage object inside an OpenAI realtime `response.done` event.
interface RealtimeUsage {
  input_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
    cached_tokens?: number;
  };
  output_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
  };
}

export class RealtimeMeterDO {
  private state: DurableObjectState;
  private env: Env;
  // sideband mode: the control connection. proxy mode: the OpenAI leg.
  private upstreamWs: WebSocket | null = null;
  // proxy mode only: the iOS-facing leg.
  private clientWs: WebSocket | null = null;
  private ctx: MeterContext | null = null;
  private turnIndex = 0;
  private closed = false;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // proxy mode: iOS opens a WebSocket to the worker, the worker
    // forwards the upgrade here.
    if (request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      return this.handleProxyUpgrade();
    }
    // sideband mode: open the WebRTC control connection.
    if (url.pathname === '/sideband' && request.method === 'POST') {
      return this.startSideband((await request.json()) as MeterContext);
    }
    // proxy mode: stash the call context before iOS upgrades.
    if (url.pathname === '/prepare' && request.method === 'POST') {
      const ctx = (await request.json()) as MeterContext;
      this.ctx = ctx;
      await this.state.storage.put('ctx', ctx);
      return Response.json({ ok: true });
    }
    if (url.pathname === '/stop' && request.method === 'POST') {
      await this.finalize();
      return Response.json({ ok: true });
    }
    return new Response('not found', { status: 404 });
  }

  // ── sideband (WebRTC) ────────────────────────────────────────────

  private async startSideband(ctx: MeterContext): Promise<Response> {
    const existing =
      this.ctx ?? (await this.state.storage.get<MeterContext>('ctx'));
    if (existing) return Response.json({ ok: true });

    const key = this.env.OPENAI_API_KEY;
    if (!key) return new Response('openai key not configured', { status: 503 });

    this.ctx = ctx;
    await this.state.storage.put('ctx', ctx);

    let resp: Response;
    try {
      resp = await fetch(this.realtimeUrl(`call_id=${encodeURIComponent(ctx.callId!)}`), {
        headers: this.upstreamHeaders(key),
      });
    } catch (err) {
      console.warn('[realtime-meter] sideband connect failed', err);
      return new Response('sideband connect failed', { status: 502 });
    }
    const ws = resp.webSocket;
    if (!ws) {
      console.warn('[realtime-meter] no webSocket on response', resp.status);
      return new Response('sideband upgrade failed', { status: 502 });
    }
    ws.accept();
    this.upstreamWs = ws;
    ws.addEventListener('message', (ev) => {
      this.onUpstreamMessage(ev).catch((err) =>
        console.warn('[realtime-meter] settle failed', err),
      );
    });
    ws.addEventListener('close', () => this.finalize().catch(() => undefined));
    ws.addEventListener('error', () => this.finalize().catch(() => undefined));

    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    return Response.json({ ok: true });
  }

  // ── proxy (WebSocket) ────────────────────────────────────────────

  private async handleProxyUpgrade(): Promise<Response> {
    const ctx = this.ctx ?? (await this.state.storage.get<MeterContext>('ctx'));
    if (!ctx || ctx.transport !== 'proxy') {
      return new Response('session not prepared', { status: 400 });
    }
    this.ctx = ctx;
    const key = this.env.OPENAI_API_KEY;
    if (!key) return new Response('openai key not configured', { status: 503 });

    let resp: Response;
    try {
      resp = await fetch(
        this.realtimeUrl(`model=${encodeURIComponent(ctx.model ?? OPENAI_MODEL_SLUG)}`),
        { headers: this.upstreamHeaders(key) },
      );
    } catch (err) {
      console.warn('[realtime-meter] proxy upstream connect failed', err);
      return new Response('upstream connect failed', { status: 502 });
    }
    const upstream = resp.webSocket;
    if (!upstream) {
      return new Response('upstream upgrade failed', { status: 502 });
    }
    upstream.accept();
    this.upstreamWs = upstream;

    // iOS-facing leg.
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    this.clientWs = server;

    // Relay. The realtime WebSocket protocol is JSON-framed both ways
    // (audio rides as base64 inside input_audio_buffer.append /
    // response.audio.delta), so a plain frame relay covers audio too.
    let clientAudioFrames = 0;
    server.addEventListener('message', (ev) => {
      try {
        upstream.send(ev.data);
      } catch {
        // upstream gone
      }
      // Diagnostic: is iOS actually streaming mic audio upstream?
      if (typeof ev.data !== 'string') return;
      let t: string | undefined;
      try {
        t = (JSON.parse(ev.data) as { type?: string }).type;
      } catch {
        return;
      }
      if (t === 'input_audio_buffer.append') {
        clientAudioFrames++;
        if (clientAudioFrames === 1 || clientAudioFrames % 100 === 0) {
          console.log('[realtime-meter] client audio frames', clientAudioFrames);
        }
      } else if (t) {
        console.log('[realtime-meter] client event', t);
      }
    });
    upstream.addEventListener('message', (ev) => {
      try {
        server.send(ev.data);
      } catch {
        // client gone
      }
      this.onUpstreamMessage(ev).catch((err) =>
        console.warn('[realtime-meter] settle failed', err),
      );
    });
    server.addEventListener('close', () => this.finalize().catch(() => undefined));
    server.addEventListener('error', () => this.finalize().catch(() => undefined));
    upstream.addEventListener('close', () => this.finalize().catch(() => undefined));
    upstream.addEventListener('error', () => this.finalize().catch(() => undefined));

    // Configure the session server-side. iOS never sends instructions —
    // the persona is assembled by the worker and baked here.
    upstream.send(
      JSON.stringify({
        type: 'session.update',
        session: {
          type: 'realtime',
          instructions: ctx.instructions ?? '',
          output_modalities: ['audio'],
          audio: {
            input: {
              format: { type: 'audio/pcm', rate: 24000 },
              transcription: { model: 'whisper-1' },
            },
            output: { format: { type: 'audio/pcm', rate: 24000 }, voice: 'marin' },
          },
        },
      }),
    );

    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    return new Response(null, { status: 101, webSocket: client });
  }

  // ── shared ───────────────────────────────────────────────────────

  // Route the realtime socket through the AI Gateway when it's
  // configured, so voice usage lands in the gateway dashboard. The
  // earlier HTTP 500 on the WS upgrade was caused by the OpenAI-Beta
  // header (the GA endpoint rejects it) — not by the gateway; with that
  // header gone the gateway proxies the realtime WS fine.
  private realtimeUrl(query: string): string {
    if (this.env.CF_ACCOUNT_ID && this.env.CF_AIG_GATEWAY) {
      return (
        `https://gateway.ai.cloudflare.com/v1/${this.env.CF_ACCOUNT_ID}` +
        `/${this.env.CF_AIG_GATEWAY}/openai?${query}`
      );
    }
    return `https://api.openai.com/v1/realtime?${query}`;
  }

  private upstreamHeaders(openaiKey: string): Record<string, string> {
    // No `OpenAI-Beta: realtime=v1` — that header marks the retired beta
    // realtime API; the GA endpoint rejects it ("the realtime beta api
    // is no longer supported"). The OpenAI key rides inline as
    // Authorization (BYOK-style — not Unified Billing), and
    // cf-aig-authorization authenticates to the gateway.
    const headers: Record<string, string> = {
      Upgrade: 'websocket',
      Authorization: `Bearer ${openaiKey}`,
    };
    if (this.env.CF_AIG_RUN_TOKEN) {
      headers['cf-aig-authorization'] = `Bearer ${this.env.CF_AIG_RUN_TOKEN}`;
    }
    return headers;
  }

  private async onUpstreamMessage(ev: MessageEvent): Promise<void> {
    if (typeof ev.data !== 'string') return;
    let msg: { type?: string; response?: { usage?: RealtimeUsage } };
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    // Diagnostic — surface the realtime event stream server-side via the
    // sideband so `wrangler tail` shows what the session is doing.
    console.log('[realtime-meter] event', msg.type ?? '(no type)');
    if (msg.type === 'session.created' || msg.type === 'session.updated') {
      console.log(
        '[realtime-meter]',
        msg.type,
        JSON.stringify(msg).slice(0, 900),
      );
    }
    if (msg.type === 'error') {
      console.warn(
        '[realtime-meter] realtime error event',
        JSON.stringify(msg).slice(0, 600),
      );
    }
    // Every completed model response carries a usage block — one audit
    // row per turn, billed from OpenAI's own numbers over this socket.
    if (msg.type !== 'response.done' || !msg.response?.usage) return;
    await this.settleTurn(msg.response.usage);
  }

  private async settleTurn(usage: RealtimeUsage): Promise<void> {
    const ctx = this.ctx;
    if (!ctx || this.closed) return;

    const inAudio = usage.input_token_details?.audio_tokens ?? 0;
    const inCached = usage.input_token_details?.cached_tokens ?? 0;
    // cached_tokens is a subset of the input tokens already counted in
    // audio/text. computeCost charges full price for audioInputTokens
    // AND cached price for cacheReadTokens, so leaving cached inside
    // audioInputTokens double-charges that slice. Subtract it out.
    const audioInputTokens = Math.max(0, inAudio - inCached);

    const supa = serviceClient(this.env);
    let route;
    try {
      route = await resolveRoute(supa, this.env, {
        modelSlug: OPENAI_MODEL_SLUG,
        taskType: 'voice_call',
        preferProvider: 'openai',
        metadata: { userId: ctx.userId, conversationId: ctx.conversationId },
      });
    } catch (err) {
      console.warn('[realtime-meter] resolveRoute failed', err);
      return;
    }

    await enqueueAudit(this.env, route, {
      userId: ctx.userId,
      conversationId: ctx.conversationId,
      taskType: 'voice_call',
      startedAt: Date.now(),
      status: 'success',
      inputTokens: usage.input_token_details?.text_tokens ?? 0,
      outputTokens: usage.output_token_details?.text_tokens ?? 0,
      audioInputTokens,
      audioOutputTokens: usage.output_token_details?.audio_tokens ?? 0,
      cacheReadTokens: inCached,
      metadata: {
        source: 'voice_call',
        session_id: ctx.sessionId,
        turn_index: this.turnIndex++,
      },
    });

    await this.enforceBalance(ctx);
  }

  // After a turn is billed, drop the call if the user can't afford it.
  // The debit runs through AUDIT_QUEUE so the balance read can lag one
  // turn — acceptable. 0/null threshold disables the gate.
  private async enforceBalance(ctx: MeterContext): Promise<void> {
    const supa = serviceClient(this.env);
    const [balance, threshold] = await Promise.all([
      getBalance(supa, ctx.userId),
      getConfigInt(supa, 'min_balance_threshold'),
    ]);
    const minThreshold = threshold ?? 0;
    if (minThreshold > 0 && (balance?.balance_credits ?? 0) < minThreshold) {
      await this.endCall();
    }
  }

  // End the call. proxy mode: closing the sockets tears it down. sideband
  // mode: the audio is a separate WebRTC link, so we ask OpenAI to hang
  // up the call by id; the sideband's close event then drives finalize.
  private async endCall(): Promise<void> {
    const ctx = this.ctx;
    if (ctx?.transport === 'sideband' && ctx.callId && this.env.OPENAI_API_KEY) {
      try {
        await fetch(
          `https://api.openai.com/v1/realtime/calls/${encodeURIComponent(ctx.callId)}/hangup`,
          { method: 'POST', headers: { Authorization: `Bearer ${this.env.OPENAI_API_KEY}` } },
        );
      } catch (err) {
        console.warn('[realtime-meter] hangup failed', err);
      }
    }
    await this.finalize();
  }

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    for (const ws of [this.clientWs, this.upstreamWs]) {
      try {
        ws?.close();
      } catch {
        // already closing
      }
    }
    this.clientWs = null;
    this.upstreamWs = null;
    const ctx = this.ctx ?? (await this.state.storage.get<MeterContext>('ctx'));
    if (ctx) {
      await endRealtimeSession(this.env, ctx.sessionId).catch(() => undefined);
    }
    await this.state.storage.deleteAlarm().catch(() => undefined);
    await this.state.storage.deleteAll().catch(() => undefined);
  }

  // Wall-clock cap — end the call and finalize even if no socket closed
  // cleanly (client vanished, network dropped).
  async alarm(): Promise<void> {
    await this.endCall();
  }
}
