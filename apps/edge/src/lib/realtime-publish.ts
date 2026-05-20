import type { Env } from '../types';

// The six tables that the CF realtime layer fans out — the same set that
// was subscribed via Supabase Realtime. conv:* tables route by
// conversation_id, user:* tables route by user_id.
export type RealtimeTable =
  | 'messages'
  | 'bot_lookbacks'
  | 'group_continue_requests'
  | 'conversation_participants'
  | 'user_unread_counts'
  | 'scroll_runs';

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
  // 'state'  — full snapshot (started/joined/pending changed)
  // 'ended'  — the room finalized; banner should disappear
  event: 'state' | 'ended';
  conversation_id: string;
  started_at?: number; // ms epoch; absent on 'ended'
  initiator_id?: string;
  // Joined participants (humans + bots that have an active leg).
  participants?: Array<{ kind: 'human' | 'bot'; id: string }>;
  // Invited but not joined yet.
  pending?: Array<{ kind: 'human' | 'bot'; id: string; invited_by: string }>;
}

// One frame a hub subscriber sees over the WebSocket. The Cloudflare
// realtime hub is content-agnostic; this union just narrows what consumers
// branch on.
export type RealtimeEvent = RealtimeChange | VoiceCallEvent;

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
