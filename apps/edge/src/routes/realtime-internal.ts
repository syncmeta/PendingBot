// Realtime fan-in — the receiving end of the Supabase Database Webhooks.
//
//   POST /v1/realtime-internal/notify
//
// Each of the six realtime tables (see lib/realtime-publish.ts) has a
// pg_net trigger that POSTs every INSERT/UPDATE/DELETE here. This route
// resolves the row to a hub topic and forwards it to the RealtimeHubDO,
// which fans it out to connected WebSocket clients.
//
// Auth: this route is called by Postgres, not by an authenticated user,
// so it is NOT behind requireSession. It is gated by a shared secret
// (REALTIME_WEBHOOK_SECRET) the trigger sends in X-Webhook-Secret. The
// route is mounted at its own path so the requireSession middleware on
// realtimeHubRoutes never applies to it.

import { Hono } from 'hono';
import { jsonError } from '../lib/http-error';
import { publishToHub, type RealtimeChange, type RealtimeTable } from '../lib/realtime-publish';
import type { AppBindings } from '../types';

export const realtimeInternalRoutes = new Hono<AppBindings>();

// Tables routed to a per-conversation hub vs a per-user hub.
const CONV_TABLES = new Set<RealtimeTable>([
  'messages',
  'bot_lookbacks',
  'group_continue_requests',
  'conversation_participants',
]);
const USER_TABLES = new Set<RealtimeTable>(['user_unread_counts', 'envelope_runs']);
// Crew tables also land on a `conv:<id>` topic, but their routing key is
// `crew_conversation_id` (a crew is a conversation; the crew chat already
// subscribes to that conv topic). T4.5 crew live-push.
const CREW_CONV_TABLES = new Set<RealtimeTable>(['crew_announcements', 'crew_sessions']);

interface WebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  schema?: string;
  record: Record<string, unknown> | null;
  old_record: Record<string, unknown> | null;
}

realtimeInternalRoutes.post('/notify', async (c) => {
  const secret = c.env.REALTIME_WEBHOOK_SECRET;
  if (!secret || c.req.header('X-Webhook-Secret') !== secret) {
    return jsonError(c, 401, 'unauthorized');
  }

  let body: WebhookPayload;
  try {
    body = await c.req.json<WebhookPayload>();
  } catch {
    return jsonError(c, 400, 'invalid_body');
  }

  const table = body.table as RealtimeTable;
  if (!CONV_TABLES.has(table) && !USER_TABLES.has(table) && !CREW_CONV_TABLES.has(table)) {
    // A webhook on a table we don't fan out — accept so the trigger
    // doesn't see an error, but do nothing.
    return c.json({ ok: true, skipped: 'table not fanned out' });
  }

  const op =
    body.type === 'INSERT' ? 'insert' : body.type === 'UPDATE' ? 'update' : 'delete';
  // DELETE carries the row in old_record; INSERT/UPDATE in record.
  const row = body.record ?? body.old_record;
  if (!row) return c.json({ ok: true, skipped: 'no row payload' });

  let hubKey: string | null = null;
  if (CONV_TABLES.has(table)) {
    const convId = row.conversation_id;
    if (typeof convId === 'string') hubKey = `conv:${convId}`;
  } else if (CREW_CONV_TABLES.has(table)) {
    // crew_announcements / crew_sessions carry crew_conversation_id, not
    // conversation_id — but a crew is a conversation, so they fan out on
    // the same conv topic.
    const crewConvId = row.crew_conversation_id;
    if (typeof crewConvId === 'string') hubKey = `conv:${crewConvId}`;
  } else {
    const uid = row.user_id;
    if (typeof uid === 'string') hubKey = `user:${uid}`;
  }
  if (!hubKey) return c.json({ ok: true, skipped: 'no routing key on row' });

  const event: RealtimeChange = { type: 'change', table, op, record: row };
  const delivered = await publishToHub(c.env, hubKey, event);
  return c.json({ ok: true, delivered });
});
