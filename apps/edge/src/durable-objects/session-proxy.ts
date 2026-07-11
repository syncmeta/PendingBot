// SessionProxyDO — the cross-device remote-control plane for one crew
// session (spec v2 §8.2 unified runtime location + §9.6 跨端遥控).
//
// One instance per active crew session (keyed by session_id via
// SESSION_PROXY_DO.idFromName(sessionId)). It is the edge hub that lets any
// logged-in client on the SAME account watch and remote-control a session
// whose agent actually runs on a different machine — a PendingCrew Mac
// today, a Fly machine in v1.1. Because `peer_device` and `fly_machine`
// share this exact channel, the DO is deliberately location-agnostic.
//
// Two kinds of peers connect over WebSocket:
//
//   * viewers — many at once. iOS PendingBot / iPad PendingCrew / Mac
//     PendingBot|PendingCrew. They send session.command + permission.decision
//     and receive session.state + permission.request fan-out.
//   * runner — at most one. The host running the agent. It sends
//     session.state + permission.request and receives delivered commands +
//     permission decisions. On (re)connect it gets the offline command
//     queue flushed to it.
//
// Auth is done at the HTTP route (routes/session-proxy.ts) BEFORE the
// upgrade is forwarded here — the route resolves the session row, checks
// the device-grant subject / JWT crew-view ACL, and stamps the trusted,
// server-derived facts onto request headers (X-Proxy-Role / X-Proxy-Subject
// / X-Proxy-User-Id). The DO never re-parses a bearer token; it trusts the
// headers because only the worker (not the client) can reach the DO's fetch.
//
// Connection model follows the non-hibernation addEventListener style used
// by RoomVoiceDO / RealtimeMeterDO (accept() + addEventListener). Hibernation
// is a fine future optimization but would diverge from the two reference DOs;
// kept consistent on purpose.

import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { uuidv7 } from '../lib/ids';
import {
  COMMAND_MAILBOX_KIND,
  parseClientMessage,
  type ProxyRole,
  type ProxyToClientMsg,
  type SessionCommandMsg,
  type PermissionDecisionMsg,
  type SessionStateMsg,
  type PermissionRequestMsg,
} from '../lib/session-proxy-protocol';

// Trusted facts the route stamps onto the forwarded upgrade request. The DO
// reads these instead of re-authenticating — only the worker can reach the
// DO so the headers are trustworthy.
const HDR_ROLE = 'X-Proxy-Role';
const HDR_SUBJECT = 'X-Proxy-Subject';
const HDR_USER = 'X-Proxy-User-Id';
const HDR_SESSION = 'X-Proxy-Session-Id';

// Bound the offline queue so a runner that stays offline forever can't grow
// DO storage without limit. Oldest commands are dropped past this cap (the
// durable mailbox is still the source of truth — the runner's inbox pull
// reconstructs anything dropped here).
const MAX_OFFLINE_QUEUE = 500;

interface QueuedCommand {
  commandId: string;
  kind: string;
  payload?: Record<string, unknown>;
  enqueuedAt: number;
}

// A connected peer. We tag each accepted socket with its authorized role +
// identity so message handling can branch without re-reading headers.
export interface Peer {
  ws: WebSocket;
  role: ProxyRole;
  subjectId: string | null;
  userId: string | null;
}

export class SessionProxyDO {
  private state: DurableObjectState;
  private env: Env;

  private sessionId: string | null = null;
  private subscribers = new Set<Peer>();
  private runner: Peer | null = null;
  private runnerSocket: WebSocket | null = null;

  // Mirrors the persisted DO-storage queue. Loaded lazily on first runner
  // (re)connect so an evicted-then-revived DO still has it.
  private offlineCommandQueue: QueuedCommand[] = [];
  private queueLoaded = false;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('expected websocket upgrade', { status: 426 });
    }
    const role = request.headers.get(HDR_ROLE);
    if (role !== 'viewer' && role !== 'runner') {
      return new Response('missing or invalid proxy role', { status: 400 });
    }
    const sessionId = request.headers.get(HDR_SESSION);
    if (!sessionId) {
      return new Response('missing session id', { status: 400 });
    }
    this.sessionId = sessionId;

    const peer: Peer = {
      // server side of the pair — set below
      ws: undefined as unknown as WebSocket,
      role,
      subjectId: request.headers.get(HDR_SUBJECT),
      userId: request.headers.get(HDR_USER),
    };

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    peer.ws = server;

    this.attach(peer);

    return new Response(null, { status: 101, webSocket: client });
  }

  // ── test seam ──────────────────────────────────────────────────────
  //
  // Vitest runs in plain node without WebSocketPair / DurableObjectState, so
  // tests construct the DO with a fake state + env and drive the message
  // router directly. This builds a peer around a fake socket and sets the
  // DO's session id — same bookkeeping `fetch` does after the upgrade, minus
  // the real WebSocketPair. Not used by the production fetch path.
  __makePeerForTest(opts: {
    role: ProxyRole;
    ws: WebSocket;
    subjectId?: string | null;
    userId?: string | null;
    sessionId?: string;
  }): Peer {
    if (opts.sessionId) this.sessionId = opts.sessionId;
    return {
      ws: opts.ws,
      role: opts.role,
      subjectId: opts.subjectId ?? null,
      userId: opts.userId ?? null,
    };
  }

  // ── socket lifecycle ───────────────────────────────────────────────

  private attach(peer: Peer): void {
    const { ws } = peer;
    ws.addEventListener('message', (ev) => {
      if (typeof ev.data !== 'string') return;
      this.onMessage(peer, ev.data).catch((err) =>
        console.warn('[session-proxy] message handler failed', err),
      );
    });
    ws.addEventListener('close', () => this.onClose(peer));
    ws.addEventListener('error', () => this.onClose(peer));
  }

  private onClose(peer: Peer): void {
    if (peer.role === 'runner') {
      if (this.runner === peer) {
        this.runner = null;
        this.runnerSocket = null;
      }
    } else {
      this.subscribers.delete(peer);
    }
  }

  // The core message router. Exposed shape so unit tests can drive it with
  // a fake WebSocket peer without standing up a real DO/upgrade.
  async onMessage(peer: Peer, raw: string): Promise<void> {
    const msg = parseClientMessage(raw);
    if (!msg) {
      this.sendTo(peer, { type: 'error', code: 'bad_message', message: 'unparseable frame' });
      return;
    }
    switch (msg.type) {
      case 'subscribe':
        await this.handleSubscribe(peer, msg.role);
        return;
      case 'session.command':
        await this.handleCommand(peer, msg);
        return;
      case 'permission.decision':
        await this.handlePermissionDecision(peer, msg);
        return;
      case 'session.state':
        this.handleState(peer, msg);
        return;
      case 'permission.request':
        await this.handlePermissionRequest(peer, msg);
        return;
    }
  }

  // ── subscribe ──────────────────────────────────────────────────────

  private async handleSubscribe(peer: Peer, claimedRole: ProxyRole): Promise<void> {
    // The role the client claims in the frame must match the role the route
    // authorized (stamped on the peer). A viewer can't promote itself to
    // runner by lying in the subscribe frame.
    if (claimedRole !== peer.role) {
      this.sendTo(peer, {
        type: 'error',
        code: 'role_mismatch',
        message: `subscribe role "${claimedRole}" does not match authorized role "${peer.role}"`,
      });
      return;
    }

    if (peer.role === 'runner') {
      // Newest runner wins — drop a stale predecessor's socket so a
      // reconnected runner becomes authoritative.
      if (this.runner && this.runner !== peer) {
        try {
          this.runner.ws.close(1000, 'superseded by new runner');
        } catch {
          // already closing
        }
      }
      this.runner = peer;
      this.runnerSocket = peer.ws;
      this.sendTo(peer, { type: 'subscribed', sessionId: this.sessionId ?? '', role: 'runner' });
      await this.flushOfflineQueue(peer);
      return;
    }

    this.subscribers.add(peer);
    this.sendTo(peer, { type: 'subscribed', sessionId: this.sessionId ?? '', role: 'viewer' });
  }

  // ── session.command (any peer → runner) ────────────────────────────

  private async handleCommand(peer: Peer, msg: SessionCommandMsg): Promise<void> {
    const commandId = msg.commandId ?? uuidv7();
    const kind = msg.command?.kind;
    if (typeof kind !== 'string' || kind.length === 0) {
      this.sendTo(peer, { type: 'error', code: 'invalid_command', message: 'command.kind required' });
      return;
    }
    const payload = msg.command.payload;

    // Always persist to the durable mailbox first — the runner's inbox pull
    // is the authoritative delivery path; the live socket / offline queue
    // are just the low-latency fast path. Best-effort: a persistence failure
    // doesn't block live delivery (logged, surfaced as an error frame only
    // if the runner is also offline so the command would otherwise vanish).
    const persisted = await this.persistCommandToMailbox(kind, payload).catch((err) => {
      console.warn('[session-proxy] persist command failed', err);
      return false;
    });

    if (this.runnerSocket && this.runner) {
      this.sendTo(this.runner, {
        type: 'session.command',
        commandId,
        command: { kind, payload },
      });
      this.sendTo(peer, { type: 'session.command.ack', commandId, disposition: 'delivered' });
      return;
    }

    // Runner offline — cache for flush on its next connect.
    await this.enqueueOffline({ commandId, kind, payload, enqueuedAt: Date.now() });
    if (!persisted) {
      // Both fast paths failed AND the durable path failed — tell the sender
      // so it doesn't assume the command landed.
      this.sendTo(peer, {
        type: 'error',
        code: 'command_not_persisted',
        message: 'runner offline and mailbox persist failed; command queued in volatile DO state only',
      });
    }
    this.sendTo(peer, { type: 'session.command.ack', commandId, disposition: 'queued' });
  }

  // ── session.state (runner → viewers) ───────────────────────────────

  private handleState(peer: Peer, msg: SessionStateMsg): void {
    // Only the runner publishes state. A viewer sending session.state is a
    // protocol violation — drop it rather than fan out client-forged state.
    if (peer.role !== 'runner') {
      this.sendTo(peer, {
        type: 'error',
        code: 'forbidden',
        message: 'only the runner may publish session.state',
      });
      return;
    }
    this.broadcastToViewers({ type: 'session.state', state: msg.state });
  }

  // ── permission.request (runner → viewers + persist) ────────────────

  private async handlePermissionRequest(peer: Peer, msg: PermissionRequestMsg): Promise<void> {
    if (peer.role !== 'runner') {
      this.sendTo(peer, {
        type: 'error',
        code: 'forbidden',
        message: 'only the runner may raise a permission.request',
      });
      return;
    }
    const action = msg.request?.action;
    if (typeof action !== 'string' || action.trim().length === 0) {
      this.sendTo(peer, { type: 'error', code: 'invalid_request', message: 'request.action required' });
      return;
    }

    // Persist via the T4.3 RPC so the request also lands on the whiteboard
    // and survives DO eviction. The returned id becomes the canonical
    // request id for the fan-out and the later decision round-trip.
    const requestId = await this.persistPermissionRequest(
      action,
      msg.request.payload,
      msg.request.riskLevel,
    ).catch((err) => {
      console.warn('[session-proxy] persist permission request failed', err);
      return msg.request.id ?? uuidv7();
    });

    this.broadcastToViewers({
      type: 'permission.request',
      request: {
        id: requestId,
        action,
        payload: msg.request.payload,
        riskLevel: msg.request.riskLevel,
      },
    });

    // Ack the runner with the canonical persisted id, echoing its own
    // `request.id` (local approval id) so it can correlate the later
    // permission.decision (which carries the persisted id) back onto the
    // local approval that is blocking the agent.
    this.sendTo(peer, {
      type: 'permission.request.ack',
      requestId,
      ...(msg.request.id ? { clientRequestId: msg.request.id } : {}),
    });
  }

  // ── permission.decision (viewer → runner + persist) ────────────────

  private async handlePermissionDecision(peer: Peer, msg: PermissionDecisionMsg): Promise<void> {
    if (peer.role !== 'viewer') {
      this.sendTo(peer, {
        type: 'error',
        code: 'forbidden',
        message: 'only a viewer may submit a permission.decision',
      });
      return;
    }
    if (typeof msg.requestId !== 'string' || !msg.requestId) {
      this.sendTo(peer, { type: 'error', code: 'invalid_decision', message: 'requestId required' });
      return;
    }
    if (msg.decision !== 'approve' && msg.decision !== 'reject') {
      this.sendTo(peer, { type: 'error', code: 'invalid_decision', message: 'decision must be approve|reject' });
      return;
    }

    // Persist via the T4.3 RPC (the route already verified this viewer can
    // act on the session, but decide_permission_request re-checks the ACL
    // against the deciding user — defence in depth). Best-effort: a failed
    // persist still routes to the runner so the live unblock isn't lost, but
    // surfaces an error frame to the decider.
    if (peer.userId) {
      const ok = await this.persistDecision(msg.requestId, msg.decision, peer.userId).catch((err) => {
        console.warn('[session-proxy] persist decision failed', err);
        return false;
      });
      if (!ok) {
        this.sendTo(peer, {
          type: 'error',
          code: 'decision_not_persisted',
          message: 'decision routed to runner but not persisted (ACL or db error)',
        });
      }
    }

    // Route the decision to the runner so it can unblock the paused action.
    // Runner offline → ride the offline command queue (flushed on its next
    // connect as a session.command kind='permission.decision'); the paused
    // agent would otherwise wait forever on a decision that only landed in
    // the DB. No mailbox persist — decide_permission_request above is the
    // durable record.
    if (this.runnerSocket && this.runner) {
      this.sendTo(this.runner, {
        type: 'permission.decision',
        requestId: msg.requestId,
        decision: msg.decision,
      });
    } else {
      await this.enqueueOffline({
        commandId: uuidv7(),
        kind: 'permission.decision',
        payload: { requestId: msg.requestId, decision: msg.decision },
        enqueuedAt: Date.now(),
      });
    }
    // Fan the decision back out to other viewers too so every端 clears its
    // pending card without a refetch.
    this.broadcastToViewers(
      {
        type: 'permission.request',
        request: {
          id: msg.requestId,
          action: '',
          payload: { status: msg.decision === 'approve' ? 'approved' : 'denied' },
        },
      },
      peer,
    );
  }

  // ── offline command queue ──────────────────────────────────────────

  private async loadQueue(): Promise<void> {
    if (this.queueLoaded) return;
    const stored = await this.state.storage.get<QueuedCommand[]>('offlineCommandQueue');
    this.offlineCommandQueue = Array.isArray(stored) ? stored : [];
    this.queueLoaded = true;
  }

  private async enqueueOffline(cmd: QueuedCommand): Promise<void> {
    await this.loadQueue();
    this.offlineCommandQueue.push(cmd);
    // Drop oldest past the cap — durable mailbox remains the backstop.
    if (this.offlineCommandQueue.length > MAX_OFFLINE_QUEUE) {
      this.offlineCommandQueue.splice(0, this.offlineCommandQueue.length - MAX_OFFLINE_QUEUE);
    }
    await this.state.storage.put('offlineCommandQueue', this.offlineCommandQueue);
  }

  private async flushOfflineQueue(runnerPeer: Peer): Promise<void> {
    await this.loadQueue();
    if (this.offlineCommandQueue.length === 0) return;
    const pending = this.offlineCommandQueue;
    this.offlineCommandQueue = [];
    await this.state.storage.delete('offlineCommandQueue');
    for (const cmd of pending) {
      this.sendTo(runnerPeer, {
        type: 'session.command',
        commandId: cmd.commandId,
        command: { kind: cmd.kind, payload: cmd.payload },
        queued: true,
      });
    }
  }

  // ── persistence helpers (T4.1 / T4.3 RPCs) ─────────────────────────

  private async persistCommandToMailbox(
    kind: string,
    payload?: Record<string, unknown>,
  ): Promise<boolean> {
    if (!this.sessionId) return false;
    const svc = serviceClient(this.env) as unknown as {
      rpc: (
        name: string,
        args: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>;
    };
    const summary = `[remote-command] ${kind}`;
    const { error } = await svc.rpc('enqueue_session_mailbox', {
      p_session_id: this.sessionId,
      p_message_kind: COMMAND_MAILBOX_KIND,
      p_summary: summary,
      p_payload: { source: 'cross_device_remote', command_kind: kind, ...(payload ? { command_payload: payload } : {}) },
    });
    if (error) {
      console.warn('[session-proxy] enqueue_session_mailbox error', error.message);
      return false;
    }
    return true;
  }

  private async persistPermissionRequest(
    action: string,
    payload: Record<string, unknown> | undefined,
    riskLevel: 'low' | 'medium' | 'high' | undefined,
  ): Promise<string> {
    if (!this.sessionId) return uuidv7();
    const svc = serviceClient(this.env) as unknown as {
      rpc: (
        name: string,
        args: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>;
    };
    const { data, error } = await svc.rpc('create_permission_request', {
      p_session_id: this.sessionId,
      p_action: action,
      p_payload: payload ?? {},
      p_risk_level: riskLevel ?? 'medium',
    });
    if (error) {
      console.warn('[session-proxy] create_permission_request error', error.message);
      throw new Error(error.message);
    }
    return typeof data === 'string' ? data : uuidv7();
  }

  private async persistDecision(
    requestId: string,
    decision: 'approve' | 'reject',
    callerUserId: string,
  ): Promise<boolean> {
    const svc = serviceClient(this.env) as unknown as {
      rpc: (
        name: string,
        args: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>;
    };
    const { error } = await svc.rpc('decide_permission_request', {
      p_id: requestId,
      p_decision: decision,
      p_caller_user_id: callerUserId,
    });
    if (error) {
      console.warn('[session-proxy] decide_permission_request error', error.message);
      return false;
    }
    return true;
  }

  // ── send helpers ───────────────────────────────────────────────────

  private sendTo(peer: Peer, msg: ProxyToClientMsg): void {
    try {
      peer.ws.send(JSON.stringify(msg));
    } catch {
      // socket gone — close handler will reap it
    }
  }

  private broadcastToViewers(msg: ProxyToClientMsg, exclude?: Peer): void {
    const frame = JSON.stringify(msg);
    for (const peer of this.subscribers) {
      if (peer === exclude) continue;
      try {
        peer.ws.send(frame);
      } catch {
        // reaped on close
      }
    }
  }
}
