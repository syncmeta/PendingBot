// SFU-facing WebSocket endpoints for the group-voice bridge.
//
// The Cloudflare Realtime SFU's WebSocket Media Transport Adapters dial
// these URLs — they are the `endpoint` RoomVoiceDO passes when it creates
// an adapter (see lib/sfu.ts, durable-objects/room-voice.ts):
//
//   GET /v1/realtime-sfu/<roomId>/ingest/<botId>   bot voice  -> SFU track
//   GET /v1/realtime-sfu/<roomId>/stream/<humanId> human track -> bridge
//
// The media plane now lives in a container (apps/voice-container), so this
// route forwards the upgrade to the room's container instance — keyed by
// roomId (= conversation_id) via getContainer(env.ROOM_MEDIA, roomId) —
// rewriting the path to the container's /adapter/<kind>/<id> shape and
// keeping the ?t= adapter token (the container verifies it).
//
// There is deliberately no Supabase JWT gate here — the caller is the
// Cloudflare SFU, not a user. Auth is the per-room adapterToken in ?t=.

import { Hono } from 'hono';
import type { Context } from 'hono';
import { getContainer } from '@cloudflare/containers';
import type { AppBindings } from '../types';

export const roomVoiceRoutes = new Hono<AppBindings>();

function forwardToContainer(
  c: Context<AppBindings>,
  kind: 'ingest' | 'stream',
  id: string | undefined,
): Response | Promise<Response> {
  const roomId = c.req.param('roomId');
  if (!roomId || !id) return c.text('missing path params', 400);
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return c.text('expected a websocket upgrade', 400);
  }
  // Rewrite to the container's adapter path, preserving the ?t= query, and
  // forward the upgrade. The container parses kind/id itself and checks the
  // token before accepting the socket.
  const target = new URL(c.req.url);
  target.pathname = `/adapter/${kind}/${id}`;
  const stub = getContainer(c.env.ROOM_MEDIA, roomId);
  return stub.fetch(new Request(target.toString(), c.req.raw));
}

roomVoiceRoutes.get('/:roomId/ingest/:botId', (c) =>
  forwardToContainer(c, 'ingest', c.req.param('botId')),
);
roomVoiceRoutes.get('/:roomId/stream/:humanId', (c) =>
  forwardToContainer(c, 'stream', c.req.param('humanId')),
);
