import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { getModelRole } from '../lib/model-roles';
import { computeVoiceCost, resolveRoute } from '../llm/router';
import { wallet } from '../billing/wallet-client';
import { resolveUserWalletSubjectId } from '../billing/subject-key';
import { usdToPncMicros } from '../billing/pnc';
import { endRealtimeSession, REALTIME_HANG_UP_TOOL } from '../lib/realtime-sessions';
import {
  broadcastVoiceCostPreview,
  safeRealtimeErrorSummary,
  safeRealtimeEventSummary,
  splitRealtimeUsage,
  type RealtimeUsage,
  type VoiceTurnUsage,
} from '../lib/voice-metering';

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

// Voice fallback model — used when the session carries no picked model
// (ctx.model). Resolved at runtime from the board's `voiceDefault` role
// (lib/model-roles.ts) so ops can repoint it without a redeploy; the code
// default there matches the old hardcoded slug. Per-turn billing still
// prices off the model the call actually used, so a mini call prices as mini.

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
  // sideband (WebRTC) only — the ephemeral client_secret the call was
  // created with. The sideband WebSocket MUST authenticate with this,
  // not the standard API key: the WebRTC call belongs to the ephemeral
  // session, so a standard-key attach gets call_id_not_found / 404.
  clientSecret?: string;
  // proxy (WebSocket) only — model id + baked persona for session.update.
  model?: string;
  instructions?: string;
  // proxy (WebSocket) only — resolved per-bot voice/turn-detection block
  // produced by lib/voice-config. Baked into the initial session.update.
  voiceConfig?: {
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

interface RealtimeEvent {
  type?: string;
  error?: {
    type?: string;
    code?: string;
    [key: string]: unknown;
  };
  response?: {
    usage?: RealtimeUsage;
    status?: string;
    [key: string]: unknown;
  };
  session?: {
    id?: string;
    model?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
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
  /// Running pnc_micros total previewed to the in-call UI via `voice_cost`
  /// hub events. Same unit (pnc_micros, usdToPncMicros, no markup) as the
  /// WalletDO debit above, so the live figure reconciles with the wallet on
  /// hang-up — this is a display-only mirror of what actually gets debited.
  private cumulativePncMicros = 0;

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

    // The sideband authenticates with the ephemeral client_secret the
    // WebRTC call was created with — NOT the standard API key. The call
    // belongs to that ephemeral session; a standard-key attach yields
    // call_id_not_found / 404.
    const key = ctx.clientSecret;
    if (!key) return new Response('client secret not provided', { status: 503 });

    this.ctx = ctx;
    await this.state.storage.put('ctx', ctx);

    const sidebandUrl = this.realtimeUrl(
      `call_id=${encodeURIComponent(ctx.callId ?? '')}`,
    );
    console.log('[realtime-meter] sideband attaching call_id=', ctx.callId);

    // iOS calls /attach right after the SDP exchange, before the WebRTC
    // connection is fully up — the call may not be attachable for a
    // beat. Retry for a few seconds until the session exists.
    let ws: WebSocket | null = null;
    for (let attempt = 1; attempt <= 8 && !ws; attempt++) {
      if (attempt > 1) {
        await new Promise((r) => setTimeout(r, 1_000));
      }
      try {
        const resp = await fetch(sidebandUrl, {
          headers: this.upstreamHeaders(key),
        });
        if (resp.webSocket) {
          ws = resp.webSocket;
          break;
        }
        let body = '';
        try {
          body = (await resp.text()).slice(0, 200);
        } catch {
          // no body
        }
        console.warn('[realtime-meter] sideband attempt', attempt,
          'status', resp.status, body);
      } catch (err) {
        console.warn('[realtime-meter] sideband attempt', attempt, 'threw', err);
      }
    }
    if (!ws) {
      console.warn('[realtime-meter] sideband gave up after retries');
      return new Response('sideband upgrade failed', { status: 502 });
    }
    console.log('[realtime-meter] sideband connected');
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
    const proxyReq = this.proxyUpstreamRequest(ctx.model ?? (await getModelRole(this.env, 'voiceDefault')), key);
    try {
      resp = await fetch(proxyReq.url, { headers: proxyReq.headers });
    } catch (err) {
      console.warn('[realtime-meter] proxy upstream connect failed', err);
      return new Response('upstream connect failed', { status: 502 });
    }
    const upstream = resp.webSocket;
    if (!upstream) {
      let body = '';
      try {
        body = (await resp.text()).slice(0, 400);
      } catch {
        // no body
      }
      console.warn(
        '[realtime-meter] proxy upstream upgrade failed — status',
        resp.status,
        body,
      );
      return new Response('upstream upgrade failed', { status: 502 });
    }
    console.log('[realtime-meter] proxy upstream connected, status', resp.status);
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
    upstream.addEventListener('close', (ev) => {
      console.log(
        '[realtime-meter] upstream closed — code',
        (ev as CloseEvent).code,
        'reason',
        (ev as CloseEvent).reason,
      );
      this.finalize().catch(() => undefined);
    });
    upstream.addEventListener('error', () => {
      console.warn('[realtime-meter] upstream socket error');
      this.finalize().catch(() => undefined);
    });

    // Configure the session server-side. iOS never sends instructions —
    // the persona is assembled by the worker and baked here.
    try {
      const voiceId = ctx.voiceConfig?.voice ?? 'marin';
      const td = ctx.voiceConfig?.turnDetection;
      upstream.send(
        JSON.stringify({
          type: 'session.update',
          session: {
            type: 'realtime',
            instructions: ctx.instructions ?? '',
            output_modalities: ['audio'],
            // hang_up lets the bot end the call itself; iOS watches for
            // the function call and tears the call down.
            tools: [REALTIME_HANG_UP_TOOL],
            tool_choice: 'auto',
            // No input transcription — the closing recap is generated by
            // the model from its own audio context (POST /v1/realtime/summary).
            audio: {
              input: {
                format: { type: 'audio/pcm', rate: 24000 },
                // undefined → omit (OpenAI default semantic_vad); null →
                // disable VAD entirely (push-to-talk); object → apply.
                ...(td !== undefined && { turn_detection: td }),
              },
              output: { format: { type: 'audio/pcm', rate: 24000 }, voice: voiceId },
            },
          },
        }),
      );
    } catch (err) {
      console.warn('[realtime-meter] session.update send failed', err);
    }

    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    return new Response(null, { status: 101, webSocket: client });
  }

  // ── shared ───────────────────────────────────────────────────────

  // Direct OpenAI realtime endpoint — used by the sideband control
  // connection and as the proxy fallback when the AI Gateway isn't bound.
  private realtimeUrl(query: string): string {
    return `https://api.openai.com/v1/realtime?${query}`;
  }

  private upstreamHeaders(openaiKey: string): Record<string, string> {
    // No `OpenAI-Beta: realtime=v1` — that header marks the retired beta
    // realtime API; the GA endpoint (/v1/realtime) rejects it with
    // "the realtime beta api is no longer supported".
    return {
      Upgrade: 'websocket',
      Authorization: `Bearer ${openaiKey}`,
    };
  }

  // Proxy-mode upstream — connects straight to OpenAI's GA realtime
  // endpoint. Routing this through the AI Gateway was tested three ways
  // (584310d direct attempt, the gateway's dedicated /openai?model=
  // realtime route, and the /openai/realtime path passthrough): all
  // three accept the WebSocket upgrade (101) then immediately drop it
  // with code 1006 and no frames. A Cloudflare Worker can't sustain a
  // WebSocket subrequest to the AI Gateway — text LLM traffic works
  // because it's plain HTTP. Voice metering therefore stays local: the
  // DO reads response.done usage and computeVoiceCost prices it.
  private proxyUpstreamRequest(
    model: string,
    openaiKey: string,
  ): { url: string; headers: Record<string, string> } {
    return {
      url: this.realtimeUrl(`model=${encodeURIComponent(model)}`),
      headers: this.upstreamHeaders(openaiKey),
    };
  }

  private async onUpstreamMessage(ev: MessageEvent): Promise<void> {
    if (typeof ev.data !== 'string') return;
    let msg: RealtimeEvent;
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    // Keep diagnostics to a field allowlist: session events can contain
    // generated instructions and other private bot/user context.
    console.log('[realtime-meter] event', msg.type ?? '(no type)');
    if (msg.type === 'session.created' || msg.type === 'session.updated') {
      console.log('[realtime-meter] session event', safeRealtimeEventSummary(msg));
    }
    if (msg.type === 'error') {
      console.warn('[realtime-meter] realtime error event', safeRealtimeErrorSummary(msg));
    }
    // Every completed model response carries a usage block — one audit
    // row per turn, billed from OpenAI's own numbers over this socket.
    if (msg.type !== 'response.done' || !msg.response?.usage) return;
    await this.settleTurn(msg.response.usage);
  }

  private async settleTurn(usage: RealtimeUsage): Promise<void> {
    const ctx = this.ctx;
    if (!ctx || this.closed) return;

    const supa = serviceClient(this.env);
    let route;
    try {
      // Price the model the call actually used — no taskType, so a
      // task_routing_rule can't redirect billing away from what ran.
      route = await resolveRoute(supa, this.env, {
        modelSlug: ctx.model ?? (await getModelRole(this.env, 'voiceDefault')),
        preferProvider: 'openai',
        metadata: { userId: ctx.userId, conversationId: ctx.conversationId },
      });
    } catch (err) {
      console.warn('[realtime-meter] resolveRoute failed', err);
      return;
    }

    const turnUsage = splitRealtimeUsage(usage);
    const turnIndex = this.turnIndex++;

    // Billing P2: debit the caller's WalletDO per turn from OpenAI's own
    // response.done usage. Owner of a 1:1 call is the caller (ctx.userId).
    // We report the raw vendor USD (no platform markup, design §9); the DO
    // converts to pnc_micros, decrements its strong-consistent cache, and
    // queues the usage for flush to Polar. dedupeId = session + turn index
    // makes the debit idempotent under reconnect / re-delivery. The legacy
    // billing-v2 AUDIT_QUEUE settle + getBalanceGateState gate are gone.
    const vendorCostUsd = computeVoiceCost(route?.modelToCall, turnUsage);
    if (vendorCostUsd != null && vendorCostUsd > 0) {
      // 个人钱包键 = 该用户的 user_account subject id,不是 auth user id
      // (见 billing/subject-key.ts)。解析不到就这一轮不计费 + 报错级日志。
      let subjectId: string;
      try {
        subjectId = await resolveUserWalletSubjectId(supa, ctx.userId);
      } catch (err) {
        console.error('[realtime-meter] billing subject unresolved — turn left unbilled', ctx.userId, err);
        return;
      }
      try {
        const res = await wallet.debit(this.env, subjectId, usdToPncMicros(vendorCostUsd), {
          category: 'voice_tokens',
          dedupeId: `${ctx.sessionId}:${turnIndex}`,
          meta: {
            session_id: ctx.sessionId,
            conversation_id: ctx.conversationId,
            bot_id: ctx.botId,
            turn_index: turnIndex,
            vendor_cost_usd: vendorCostUsd,
          },
        });
        // Hard-stop on exhaustion (design §7 ≤0). The debit already
        // happened (the turn is spent), so we end the call after it.
        if (res.thresholdState === 'exhausted') {
          await this.endCall();
        }
      } catch (err) {
        // Billing failures must never break the live call.
        console.warn('[realtime-meter] voice debit failed', err);
      }
    }

    // Mirror the debit's pricing into the in-call UI so the user sees a
    // running spend figure within ~100 ms of the model's response.done.
    // Same unit as the WalletDO debit above (pnc_micros, no markup) so the
    // preview reconciles with the actual wallet drain on hang-up.
    void this.broadcastCost(ctx, route?.modelToCall, supa, turnUsage);
  }

  // Compute and publish this turn's PND to the caller's user hub.
  // Best-effort: failures are logged but never block the call.
  private async broadcastCost(
    ctx: MeterContext,
    modelToCall: string | undefined,
    supa: ReturnType<typeof serviceClient>,
    usage: VoiceTurnUsage,
  ): Promise<void> {
    // Route through the conv hub — same channel iOS already opens for
    // the conversation, and a 1:1 conv has only the caller subscribed
    // so the figure stays private without needing a separate user-hub
    // path. Group voice fans out on the same key in room-voice.ts.
    this.cumulativePncMicros = await broadcastVoiceCostPreview({
      env: this.env,
      supa,
      conversationId: ctx.conversationId,
      sessionId: ctx.sessionId,
      modelToCall,
      usage,
      cumulativePncMicros: this.cumulativePncMicros,
      logPrefix: '[realtime-meter]',
    });
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
