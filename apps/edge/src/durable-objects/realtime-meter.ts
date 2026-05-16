import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveRoute, enqueueAudit } from '../llm/router';
import { getBalance, getConfigInt } from '../lib/billing';
import { endRealtimeSession } from '../lib/realtime-sessions';

// RealtimeMeterDO — server-side, tamper-proof metering for a voice call.
//
// Voice audio stays on a direct iOS↔OpenAI WebRTC connection (best
// mobile latency). But the audio path doesn't reach our server, so the
// token usage in OpenAI's `response.done` events would only be visible
// to the client — and a modified client could under-report to dodge
// billing.
//
// OpenAI's fix is the "sideband": the WebRTC call has a `call_id`
// (returned in the Location header of POST /v1/realtime/calls). A
// server can open a SECOND connection to the same session —
//   GET wss://api.openai.com/v1/realtime?call_id=<call_id>
// — which is a control channel (NOT in the audio path) that receives
// the same server events, including `response.done.usage`.
//
// This DO holds that sideband socket for one voice session. It reads
// the authoritative usage straight from OpenAI, settles each turn
// through the normal audit/billing path, and can hang the call up when
// the balance runs out. The client never reports usage.
//
// One instance per realtime session — keyed by session_id via
// env.REALTIME_METER.idFromName(sessionId). Reached only from the
// Worker's /v1/realtime/attach + /end routes.

// Hard wall-clock cap, mirrors REALTIME_SESSION_MAX_AGE_MS in
// lib/realtime-sessions.ts — past this we hang up and finalize even if
// the sideband never closed cleanly.
const MAX_CALL_MS = 30 * 60 * 1000;

// Canonical voice model slug — resolveRoute keys task_routing_rules and
// the alias price lookup off this (same value as routes/realtime.ts).
const OPENAI_MODEL_SLUG = 'gpt-realtime';

interface MeterContext {
  callId: string;
  sessionId: string;
  userId: string;
  conversationId: string;
  botId: string;
  startedAt: number;
}

// Shape of the usage object inside an OpenAI realtime `response.done`
// event. All fields optional — we default missing counts to 0.
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
  private ws: WebSocket | null = null;
  private ctx: MeterContext | null = null;
  private turnIndex = 0;
  private closed = false;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/start' && request.method === 'POST') {
      const body = (await request.json()) as MeterContext;
      return this.start(body);
    }
    if (url.pathname === '/stop' && request.method === 'POST') {
      await this.finalize();
      return Response.json({ ok: true });
    }
    return new Response('not found', { status: 404 });
  }

  // Open the sideband socket for a freshly-attached call. Idempotent:
  // a second /start for the same session (retry, or after a DO restart
  // where storage still holds the context) is a no-op.
  private async start(ctx: MeterContext): Promise<Response> {
    const existing =
      this.ctx ?? (await this.state.storage.get<MeterContext>('ctx'));
    if (existing) return Response.json({ ok: true });

    const key = this.env.OPENAI_API_KEY;
    if (!key) return new Response('openai key not configured', { status: 503 });

    this.ctx = ctx;
    await this.state.storage.put('ctx', ctx);

    // Sideband endpoint. When the AI Gateway is configured we route the
    // sideband through it (provider-native OpenAI passthrough), so the
    // voice call's token usage also shows up in the gateway dashboard.
    //
    // The OpenAI key is ALWAYS sent inline as Authorization — that pins
    // the sideband to OpenAI's own billing (BYOK-style), NOT Unified
    // Billing. The WebRTC call already bills this OpenAI account once
    // for the session; an inline-key sideband makes the gateway a pure
    // observer that never charges CF credits, so there is no double
    // charge. (If the gateway turns out not to forward `call_id`, revert
    // to the api.openai.com branch — billing then still works direct.)
    const headers: Record<string, string> = {
      Upgrade: 'websocket',
      Authorization: `Bearer ${key}`,
      'OpenAI-Beta': 'realtime=v1',
    };
    let url: string;
    if (
      this.env.CF_ACCOUNT_ID &&
      this.env.CF_AIG_GATEWAY &&
      this.env.CF_AIG_RUN_TOKEN
    ) {
      url =
        `https://gateway.ai.cloudflare.com/v1/${this.env.CF_ACCOUNT_ID}` +
        `/${this.env.CF_AIG_GATEWAY}/openai` +
        `?call_id=${encodeURIComponent(ctx.callId)}`;
      headers['cf-aig-authorization'] = `Bearer ${this.env.CF_AIG_RUN_TOKEN}`;
    } else {
      url = `https://api.openai.com/v1/realtime?call_id=${encodeURIComponent(ctx.callId)}`;
    }

    let resp: Response;
    try {
      resp = await fetch(url, { headers });
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
    this.ws = ws;
    ws.addEventListener('message', (ev) => {
      this.onMessage(ev).catch((err) =>
        console.warn('[realtime-meter] settle failed', err),
      );
    });
    ws.addEventListener('close', () => {
      this.finalize().catch(() => undefined);
    });
    ws.addEventListener('error', () => {
      this.finalize().catch(() => undefined);
    });

    await this.state.storage.setAlarm(Date.now() + MAX_CALL_MS);
    return Response.json({ ok: true });
  }

  private async onMessage(ev: MessageEvent): Promise<void> {
    if (typeof ev.data !== 'string') return;
    let msg: { type?: string; response?: { usage?: RealtimeUsage } };
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    // Every completed model response carries a usage block. That's the
    // unit we bill — one audit row per turn, same granularity as the
    // old client-reported /usage endpoint, but the numbers now come
    // straight from OpenAI over the sideband.
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
    // audioInputTokens double-charges that slice. Subtract it out
    // (cached tokens in a voice call are predominantly audio).
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

  // After a turn is billed, drop the call if the user can no longer
  // afford it. The debit runs through AUDIT_QUEUE so the balance read
  // here can lag one turn — acceptable, the old /usage gate lagged the
  // same way. A 0/null threshold disables the gate.
  private async enforceBalance(ctx: MeterContext): Promise<void> {
    const supa = serviceClient(this.env);
    const [balance, threshold] = await Promise.all([
      getBalance(supa, ctx.userId),
      getConfigInt(supa, 'min_balance_threshold'),
    ]);
    const minThreshold = threshold ?? 0;
    if (minThreshold > 0 && (balance?.balance_credits ?? 0) < minThreshold) {
      await this.hangup();
    }
  }

  // Tell OpenAI to terminate the call. Used by the balance gate and the
  // max-age alarm. The sideband's close event then drives finalize().
  private async hangup(): Promise<void> {
    const ctx = this.ctx;
    const key = this.env.OPENAI_API_KEY;
    if (!ctx || !key) return;
    try {
      await fetch(
        `https://api.openai.com/v1/realtime/calls/${encodeURIComponent(ctx.callId)}/hangup`,
        { method: 'POST', headers: { Authorization: `Bearer ${key}` } },
      );
    } catch (err) {
      console.warn('[realtime-meter] hangup failed', err);
    }
  }

  private async finalize(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try {
      this.ws?.close();
    } catch {
      // already closing
    }
    this.ws = null;
    const ctx = this.ctx ?? (await this.state.storage.get<MeterContext>('ctx'));
    if (ctx) {
      await endRealtimeSession(this.env, ctx.sessionId).catch(() => undefined);
    }
    await this.state.storage.deleteAlarm().catch(() => undefined);
    await this.state.storage.deleteAll().catch(() => undefined);
  }

  // Wall-clock cap reached — hang up and finalize. Covers the case
  // where the sideband never closed cleanly (client vanished, network
  // dropped) so the DO doesn't leak an open socket.
  async alarm(): Promise<void> {
    await this.hangup();
    await this.finalize();
  }
}
