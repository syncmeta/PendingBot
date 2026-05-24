// Entry point for the group-voice media container. One instance per room
// (the worker reaches it via getContainer(env.ROOM_MEDIA, conversationId)),
// so a single process owns one Room.
//
// Endpoints (all reached through the worker, never the public internet):
//   GET /ping                          health check (Container pingEndpoint)
//   GET /control                       WS — RoomVoiceDO control plane
//   GET /rtk/bot-page/<botId>?t=       HTML — headless bot participant
//   GET /rtk/bot/<botId>?t=            WS — bot participant audio bridge
//
// The headless RealtimeKit page connects with the per-room token in ?t=;
// the worker forwards the upgrade here and Room verifies the token.

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

    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] === 'rtk' && parts.length === 3) {
      const slot = parts[1];
      const botId = parts[2];
      if (!room.tokenMatches(url.searchParams.get('t'))) {
        return new Response('forbidden', { status: 403 });
      }
      if (slot === 'bot-page') return room.realtimeKitBotPage(botId);
      if (slot === 'bot') {
        if (server.upgrade(req, { data: { kind: 'rtk-bot', botId } })) {
          return undefined;
        }
        return new Response('expected websocket', { status: 426 });
      }
      return new Response('bad realtimekit slot', { status: 400 });
    }

    return new Response('not found', { status: 404 });
  },
  websocket: {
    // Audio control frames are already compact — no point compressing them.
    perMessageDeflate: false,
    open(ws) {
      const d = ws.data;
      if (d.kind === 'control') {
        room.onControlOpen(ws);
      } else if (d.kind === 'rtk-bot') {
        if (!room.attachRealtimeKitBot(d.botId, ws)) ws.close();
      }
    },
    message(ws, message) {
      const d = ws.data;
      if (d.kind === 'control') {
        if (typeof message === 'string') void room.onControlMessage(message);
        return;
      }
      if (d.kind === 'rtk-bot') {
        if (typeof message === 'string') room.onRealtimeKitBridgeMessage(d.botId, message);
      }
    },
    close(ws) {
      const d = ws.data;
      if (d.kind === 'control') room.onControlClose(ws);
      else if (d.kind === 'rtk-bot') room.detachRealtimeKitBot(d.botId, ws);
    },
  },
});

console.log(`[voice-container] listening on :${PORT}`);
