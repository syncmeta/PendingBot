// CF-native realtime hub — WebSocket fan-out, replacing Supabase Realtime.
//
//   GET /v1/realtime-hub/conv/:conversationId   — WebSocket, conv topic
//   GET /v1/realtime-hub/user                   — WebSocket, user topic
//
// A client opens one conv WebSocket per conversation it is viewing and
// one resident user WebSocket. The Worker verifies the Supabase JWT
// (requireSession); for conv topics it also verifies membership
// (resolveConv — RLS-gated). The user topic is keyed by the caller's own
// JWT subject, so a client can only ever reach its own user hub.
//
// Events are pushed into the hubs by the DB-webhook path — see
// routes/realtime-internal.ts. This file is the read side only.

import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { userClient } from '../lib/supabase';
import { resolveConv } from '../lib/conv-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import { UUID_RE } from '../lib/ids';
import type { AppBindings } from '../types';

export const realtimeHubRoutes = new Hono<AppBindings>();

realtimeHubRoutes.use('*', requireSession());

// Forward an already-authorized upgrade request to the hub DO for `key`.
function handoffToHub(
  env: AppBindings['Bindings'],
  rawRequest: Request,
  key: string,
  userId: string,
): Promise<Response> {
  const stub = env.REALTIME_HUB.get(env.REALTIME_HUB.idFromName(key));
  const headers = new Headers(rawRequest.headers);
  headers.set('X-Hub-User-Id', userId);
  return stub.fetch(new Request(rawRequest, { headers }));
}

realtimeHubRoutes.get('/conv/:conversationId', async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return jsonError(c, 426, 'upgrade_required', {
      message: 'WebSocket upgrade required',
    });
  }

  const conversationId = c.req.param('conversationId');
  if (!UUID_RE.test(conversationId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'bad conversation id' });
  }

  const userId = c.var.userId!;
  const supa = userClient(c.env, c.var.userJwt!);
  const conv = await resolveConv(c.env, supa, conversationId, userId, (p) =>
    safeWaitUntil(c, p),
  );
  if (!conv) {
    return jsonError(c, 404, 'conversation_not_found', {
      message: 'conversation not found',
    });
  }

  return handoffToHub(c.env, c.req.raw, `conv:${conversationId}`, userId);
});

realtimeHubRoutes.get('/user', async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return jsonError(c, 426, 'upgrade_required', {
      message: 'WebSocket upgrade required',
    });
  }
  const userId = c.var.userId!;
  return handoffToHub(c.env, c.req.raw, `user:${userId}`, userId);
});
