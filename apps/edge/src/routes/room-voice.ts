// SFU-facing WebSocket endpoints for the group-voice bridge.
//
// The Cloudflare Realtime SFU's WebSocket Media Transport Adapters dial
// these URLs — they are the `endpoint` RoomVoiceDO passes when it creates
// an adapter (see lib/sfu.ts, durable-objects/room-voice.ts):
//
//   GET /v1/realtime-sfu/<roomId>/ingest           bot voice  -> SFU track
//   GET /v1/realtime-sfu/<roomId>/stream/<humanId> human track -> bridge
//
// There is deliberately no Supabase JWT gate here — the caller is the
// Cloudflare SFU, not a user. Auth is the per-room `adapterToken` echoed
// in the `?t=` query, which RoomVoiceDO verifies before it accepts the
// socket. This route only forwards the upgrade to the room's DO.
//
// The authenticated, user-facing control surface (start/stop a room,
// register a human's SFU track) is mounted separately and is coupled to
// the group conversation model + the iOS SFU client.

import { Hono } from 'hono';
import type { Context } from 'hono';
import type { AppBindings } from '../types';

export const roomVoiceRoutes = new Hono<AppBindings>();

function forwardToRoom(c: Context<AppBindings>): Response | Promise<Response> {
  const roomId = c.req.param('roomId');
  if (!roomId) return c.text('missing roomId', 400);
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return c.text('expected a websocket upgrade', 400);
  }
  // RoomVoiceDO is keyed by roomId (= conversation_id). It parses the
  // path tail itself to tell `ingest` from `stream/<humanId>`, and checks
  // the `?t=` adapterToken — so the raw request forwards unchanged.
  const id = c.env.ROOM_VOICE.idFromName(roomId);
  return c.env.ROOM_VOICE.get(id).fetch(c.req.raw);
}

roomVoiceRoutes.get('/:roomId/ingest', forwardToRoom);
roomVoiceRoutes.get('/:roomId/stream/:humanId', forwardToRoom);
