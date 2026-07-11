// T4.5 — Cross-device session proxy protocol (spec v2 §8.2 + §9.6).
//
// The wire format for the SessionProxyDO WebSocket channel. One DO instance
// per active crew session (keyed by session_id). Two kinds of peers connect
// to the same channel:
//
//   * viewers — any logged-in client on the SAME account that wants to watch
//     / remote-control a session: iOS PendingBot, iPad PendingCrew, Mac
//     PendingBot / PendingCrew. There can be many viewers at once.
//   * runner — the single host actually running the session's agent
//     (PendingCrew Mac today, a v1.1 Fly machine tomorrow). At most one
//     runnerSocket is live; the newest runner subscribe wins.
//
// `peer_device` and `fly_machine` runtime locations share this exact channel
// — the DO is location-agnostic, which is the whole point of §8.2's unified
// abstraction. v1.1 Fly only adds the API integration + per-second billing;
// the comms layer is this file.
//
// JSON-framed both directions. Every frame has a `type` discriminator.

export type ProxyRole = 'viewer' | 'runner';

// ── client → DO ──────────────────────────────────────────────────────

/// First frame any peer sends after the socket opens. `token` is the same
/// bearer the client used on the HTTP upgrade (a `pdg_` device-grant or a
/// Supabase JWT) — the DO does NOT re-authenticate it; the route already
/// did and stamped the trusted facts onto request headers. The token here
/// is an at-most defence-in-depth echo the DO can sanity-check against what
/// the route resolved. `role` must match the role the route authorized.
export interface SubscribeMsg {
  type: 'subscribe';
  role: ProxyRole;
  token?: string;
}

/// A command from any peer (typically a viewer) targeted at the session's
/// runner. The DO routes it to the live runnerSocket when one is connected,
/// otherwise enqueues it to the offline command queue (and always persists
/// it to the session mailbox so the runner sees it on its next inbox pull
/// even if the DO is evicted). `commandId` is assigned by the DO if absent.
export interface SessionCommandMsg {
  type: 'session.command';
  commandId?: string;
  command: {
    kind: string;
    payload?: Record<string, unknown>;
  };
}

/// A permission decision from a viewer (approve/reject), routed to the
/// runner so it can unblock the paused agent action, and persisted via the
/// T4.3 decide_permission_request RPC.
export interface PermissionDecisionMsg {
  type: 'permission.decision';
  requestId: string;
  decision: 'approve' | 'reject';
}

/// A state update published by the runner — progress, new events, new
/// output. Fanned out to every viewer. `state` is intentionally free-form;
/// the runner owns its shape and clients render best-effort.
export interface SessionStateMsg {
  type: 'session.state';
  state: {
    status?: string;
    progress?: number;
    lastEvent?: string;
    [key: string]: unknown;
  };
}

/// A permission request raised by the runner (the agent hit a high-risk
/// action in manual mode). Fanned out to viewers so any authorized端 can
/// approve, and persisted via the T4.3 create_permission_request RPC.
export interface PermissionRequestMsg {
  type: 'permission.request';
  request: {
    id?: string;
    action: string;
    payload?: Record<string, unknown>;
    riskLevel?: 'low' | 'medium' | 'high';
  };
}

export type ClientToProxyMsg =
  | SubscribeMsg
  | SessionCommandMsg
  | PermissionDecisionMsg
  // The runner is also a client of the DO; these two flow runner → DO.
  | SessionStateMsg
  | PermissionRequestMsg;

// ── DO → client ──────────────────────────────────────────────────────

/// Ack of a successful subscribe.
export interface SubscribedMsg {
  type: 'subscribed';
  sessionId: string;
  role: ProxyRole;
}

/// DO → runner: a command was delivered (or flushed from the offline
/// queue). The runner translates it into its local agent queue.
export interface SessionCommandDeliverMsg {
  type: 'session.command';
  commandId: string;
  command: {
    kind: string;
    payload?: Record<string, unknown>;
  };
  // true when this command was flushed from the offline queue rather than
  // delivered live — lets the runner dedupe / order against its own state.
  queued?: boolean;
}

/// DO → sender: confirms a command was accepted (delivered live or queued).
export interface SessionCommandAckMsg {
  type: 'session.command.ack';
  commandId: string;
  // 'delivered' = handed to a live runner; 'queued' = stored for an offline
  // runner; 'persisted' = also written to the durable mailbox.
  disposition: 'delivered' | 'queued';
}

/// DO → runner: a viewer's permission decision, so the runner can unblock.
export interface PermissionDecisionDeliverMsg {
  type: 'permission.decision';
  requestId: string;
  decision: 'approve' | 'reject';
}

/// DO → runner: ack of a runner-raised permission.request. `requestId` is the
/// canonical persisted id (T4.3 permission_requests row) that viewers will
/// echo back in their permission.decision. `clientRequestId` echoes the
/// runner-supplied `request.id` (its local approval id) so the runner can map
/// server decisions back onto the local approval that is blocking the agent.
export interface PermissionRequestAckMsg {
  type: 'permission.request.ack';
  requestId: string;
  clientRequestId?: string;
}

export interface ErrorMsg {
  type: 'error';
  code: string;
  message: string;
}

export type ProxyToClientMsg =
  | SubscribedMsg
  | SessionStateMsg
  | PermissionRequestMsg
  | PermissionRequestAckMsg
  | SessionCommandDeliverMsg
  | SessionCommandAckMsg
  | PermissionDecisionDeliverMsg
  | ErrorMsg;

// ── parse helpers ────────────────────────────────────────────────────

/// Parse an inbound frame string into a typed client→DO message, or null
/// if it isn't valid JSON / lacks a known `type`. Keeps the DO's message
/// handler total without throwing on garbage.
export function parseClientMessage(raw: string): ClientToProxyMsg | null {
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!obj || typeof obj !== 'object') return null;
  const type = (obj as { type?: unknown }).type;
  if (typeof type !== 'string') return null;
  switch (type) {
    case 'subscribe':
    case 'session.command':
    case 'permission.decision':
    case 'session.state':
    case 'permission.request':
      return obj as ClientToProxyMsg;
    default:
      return null;
  }
}

/// The DB message_kind crew_announcements / session_mailbox use for a
/// remote-control command persisted to a session's mailbox. 'instruction'
/// is the existing kind for "a directive aimed at this session".
export const COMMAND_MAILBOX_KIND = 'instruction';
