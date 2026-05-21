// Entry point for the group-voice media container. One instance per room
// (the worker reaches it via getContainer(env.ROOM_MEDIA, conversationId)),
// so a single process owns one Room.
//
// Endpoints (all reached through the worker, never the public internet):
//   GET /ping                          health check (Container pingEndpoint)
//   GET /control                       WS — RoomVoiceDO control plane
//   GET /adapter/stream/<humanId>?t=   WS — SFU streams a human's mic in
//   GET /adapter/ingest/<botId>?t=     WS — SFU pulls a bot's voice out
//
// The SFU dials the adapter endpoints with the per-room token in ?t=; the
// worker forwards the upgrade here and Room verifies the token.

import { Room, type WsData } from './room';

const room = new Room();
const PORT = Number(process.env.PORT ?? 8080);

Bun.serve<WsData>({
  port: PORT,
  fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === '/ping') return new Response('ok');

    if (url.pathname === '/control') {
      if (server.upgrade(req, { data: { kind: 'control' } })) return undefined;
      return new Response('expected websocket', { status: 426 });
    }

    // /adapter/stream/<humanId> or /adapter/ingest/<botId>
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] === 'adapter' && parts.length === 3) {
      const kind = parts[1];
      const id = parts[2];
      if (kind !== 'stream' && kind !== 'ingest') {
        return new Response('bad adapter slot', { status: 400 });
      }
      if (!room.tokenMatches(url.searchParams.get('t'))) {
        return new Response('forbidden', { status: 403 });
      }
      const data: WsData =
        kind === 'stream'
          ? { kind: 'stream', humanId: id }
          : { kind: 'ingest', botId: id };
      if (server.upgrade(req, { data })) return undefined;
      return new Response('expected websocket', { status: 426 });
    }

    return new Response('not found', { status: 404 });
  },
  websocket: {
    // SFU adapter frames are binary PCM — no point compressing them.
    perMessageDeflate: false,
    open(ws) {
      const d = ws.data;
      if (d.kind === 'control') {
        room.onControlOpen(ws);
      } else if (d.kind === 'ingest') {
        if (!room.attachIngest(d.botId, ws)) ws.close();
      } else {
        room.attachStream(d.humanId, ws);
      }
    },
    message(ws, message) {
      const d = ws.data;
      if (d.kind === 'control') {
        if (typeof message === 'string') void room.onControlMessage(message);
        return;
      }
      if (d.kind === 'stream') {
        if (typeof message === 'string') return; // expect binary PCM
        room.onHumanFrame(d.humanId, message);
      }
      // ingest: the SFU pulls from us; no inbound frames expected.
    },
    close(ws) {
      const d = ws.data;
      if (d.kind === 'control') room.onControlClose(ws);
      else if (d.kind === 'ingest') room.detachIngest(d.botId, ws);
      else room.detachStream(d.humanId, ws);
    },
  },
});

console.log(`[voice-container] listening on :${PORT}`);
