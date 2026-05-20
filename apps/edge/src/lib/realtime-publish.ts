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
  | 'envelope_runs';

// Wire shape of a single row change delivered to clients over the
// WebSocket. `record` is the row as it stands after the change (for
// DELETE it's the row as it was — the DB webhook's old_record).
export interface RealtimeChange {
  type: 'change';
  table: RealtimeTable;
  op: 'insert' | 'update' | 'delete';
  record: Record<string, unknown>;
}

// Push one change to a hub topic. `hubKey` is 'conv:<id>' or
// 'user:<id>'. Returns how many sockets the DO reached (0 on failure —
// realtime is best-effort, clients refetch over HTTP on reconnect).
export async function publishToHub(
  env: Env,
  hubKey: string,
  event: RealtimeChange,
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
