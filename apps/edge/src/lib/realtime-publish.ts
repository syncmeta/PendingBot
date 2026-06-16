import type { Env } from '../types';

// Tables the CF realtime layer fans out. conv:* tables route by
// conversation_id, user:* tables by user_id, and the crew_* tables by
// crew_conversation_id (a crew IS a conversation, so they land on the same
// `conv:<id>` topic the crew chat already authorizes via resolveConv).
export type RealtimeTable =
  | 'messages'
  | 'bot_lookbacks'
  | 'group_continue_requests'
  | 'conversation_participants'
  | 'user_unread_counts'
  | 'envelope_runs'
  // T4.5 crew live-push — the crew whiteboard feed + session status. Keyed
  // by crew_conversation_id (see realtime-internal.ts routing).
  | 'crew_announcements'
  | 'crew_sessions';

// Wire shape of a single row change delivered to clients over the
// WebSocket. `record` is the row as it stands after the change (for
// DELETE it's the row as it was — the DB webhook's old_record).
export interface RealtimeChange {
  type: 'change';
  table: RealtimeTable;
  op: 'insert' | 'update' | 'delete';
  record: Record<string, unknown>;
}

// Out-of-band events the worker emits directly (no DB row backs them).
// Today: group voice call lifecycle. Conv-channel subscribers branch on
// `type === 'voice_call'` and re-render the in-conv banner / call view.
export interface VoiceCallEvent {
  type: 'voice_call';
  // 'state'        — full snapshot (started/joined/pending changed)
  // 'ended'        — the room finalized; banner should disappear
  // 'reconnecting' — the DO↔container media link dropped and the DO is
  //                  re-dialing + replaying room state; a transient
  //                  "重连中…" banner should show until a 'state' (resync
  //                  succeeded) or 'ended' (reconnect gave up) arrives.
  event: 'state' | 'ended' | 'reconnecting';
  conversation_id: string;
  started_at?: number; // ms epoch; absent on 'ended'
  initiator_id?: string;
  // Joined participants (humans + bots that have an active leg).
  participants?: Array<{ kind: 'human' | 'bot'; id: string }>;
  // Invited but not joined yet.
  pending?: Array<{ kind: 'human' | 'bot'; id: string; invited_by: string }>;
  // Optional live media diagnostics from the group-voice container.
  diagnostics?: {
    atMs: number;
    participants: Array<{
      kind: 'human' | 'bot';
      id: string;
      speaking: boolean;
      audioLevel: number;
      source: 'container' | 'model';
      playoutDepthMs?: number;
      underruns?: number;
      maxGapMs?: number;
      droppedOutputMs?: number;
      inputLevel?: number;
      inputFrames?: number;
      quietFrames?: number;
      realtimeKitConnected?: boolean;
      modelSessionReady?: boolean;
    }>;
  };
}

// Per-turn voice call cost preview. Emitted by RealtimeMeterDO (1:1) and
// RoomVoiceDO (group) right after settleTurn computes a turn's cost, so
// the in-call UI can show running spend without waiting on the WalletDO
// debit round-trip. NOT a debit — the actual debit flows through
// wallet.debit; this is purely a display mirror.
//
// Unit is **pnc_micros**: the exact same unit AND amount (no runtime
// markup) the WalletDO debits via usdToPncMicros, so the in-call figure
// reconciles with the wallet drain on hang-up. (Markup only applies on the
// Polar pack sell side, never to live vendor cost.)
//
// Routing: both 1:1 and group calls publish on `conv:<conversationId>`.
// For a 1:1 conv only the caller is a member, so the figure stays
// private to them; for a group conv every joined human sees the same
// cumulative number.
export interface VoiceCostEvent {
  type: 'voice_cost';
  conversation_id: string;
  session_id: string;
  // Per-turn delta and the running session total, in pnc_micros.
  // cumulative_pnc_micros is authoritative — clients can ignore delta and
  // just render the total.
  delta_pnc_micros: number;
  cumulative_pnc_micros: number;
  // ms epoch at which this turn settled (server clock).
  at_ms: number;
}

// One frame a hub subscriber sees over the WebSocket. The Cloudflare
// realtime hub is content-agnostic; this union just narrows what consumers
// branch on.
export type RealtimeEvent = RealtimeChange | VoiceCallEvent | VoiceCostEvent;

// Push one change to a hub topic. `hubKey` is 'conv:<id>' or
// 'user:<id>'. Returns how many sockets the DO reached (0 on failure —
// realtime is best-effort, clients refetch over HTTP on reconnect).
export async function publishToHub(
  env: Env,
  hubKey: string,
  event: RealtimeEvent,
): Promise<number> {
  const stub = env.REALTIME_HUB.get(env.REALTIME_HUB.idFromName(hubKey));
  try {
    const res = await stub.fetch('https://hub.internal/publish', {
      method: 'POST',
      body: JSON.stringify(event),
    });
    if (!res.ok) return 0;
    const json = (await res.json()) as { delivered?: number };
    return json.delivered ?? 0;
  } catch (err) {
    console.error('[realtime] publish failed', hubKey, err);
    return 0;
  }
}
