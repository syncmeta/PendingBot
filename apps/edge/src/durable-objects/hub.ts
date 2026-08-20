import type { Env } from '../types';

// RealtimeHubDO — the per-topic realtime fan-out Durable Object that
// replaces Supabase Realtime as PendingBot's delivery pipe.
//
// One instance per topic. Topics are namespaced by key prefix so a
// single DO class / binding serves both layers:
//   conv:<conversation_id>  — message / lookback / continue-request /
//                             participant changes for one conversation
//   user:<user_id>          — unread-count / envelope-run changes for one
//                             user (their resident connection)
//
// The DO holds every client's *hibernatable* WebSocket — the runtime can
// evict the DO from memory between events while the sockets stay open, so
// idle connections cost ~nothing — and fans an event out to all of them
// via the internal POST /publish seam.
//
// Reached via env.REALTIME_HUB.get(env.REALTIME_HUB.idFromName(key)).
// DO namespaces aren't publicly addressable, so the DO trusts the
// X-Hub-User-Id header the Worker sets — the Worker has already verified
// the caller's Supabase JWT (and, for conv topics, membership) before
// forwarding the upgrade. /publish is likewise only reachable from the
// Worker's webhook-notify path.

interface SocketMeta {
  userId: string;
  since: number;
}

export class RealtimeHubDO {
  state: DurableObjectState;
  env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    // Keepalive without waking the DO from hibernation: a client "ping"
    // text frame gets an automatic "pong" handled entirely by the runtime.
    this.state.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('ping', 'pong'),
    );
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      return this.handleUpgrade(request);
    }

    if (url.pathname === '/publish' && request.method === 'POST') {
      const payload = await request.text();
      const delivered = this.broadcast(payload);
      return Response.json({ ok: true, delivered });
    }

    return new Response('not found', { status: 404 });
  }

  private handleUpgrade(request: Request): Response {
    const userId = request.headers.get('X-Hub-User-Id') ?? 'unknown';
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    // Hibernatable accept — the DO may be evicted between events; the
    // socket survives and getWebSockets() rehydrates it on the next wake.
    this.state.acceptWebSocket(server, [userId]);
    const meta: SocketMeta = { userId, since: Date.now() };
    server.serializeAttachment(meta);
    server.send(JSON.stringify({ type: 'ready', ts: meta.since }));

    return new Response(null, { status: 101, webSocket: client });
  }

  // Fan a raw (already-serialized JSON) payload out to every connected
  // socket. Returns how many sockets it reached.
  private broadcast(payload: string): number {
    let delivered = 0;
    for (const ws of this.state.getWebSockets()) {
      try {
        ws.send(payload);
        delivered++;
      } catch {
        // Socket already gone — webSocketClose handles removal.
      }
    }
    return delivered;
  }

  // Hibernation handlers — invoked by the runtime, waking the DO if it
  // was evicted. The "ping" keepalive is served by the auto-response
  // pair set in the constructor and never reaches webSocketMessage.
  webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): void {
    // Clients are receive-only; inbound frames other than ping are ignored.
  }

  webSocketClose(_ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): void {
    // The runtime drops the socket from getWebSockets() once closed.
  }

  webSocketError(_ws: WebSocket, error: unknown): void {
    console.error('[RealtimeHubDO] websocket error', error);
  }
}
