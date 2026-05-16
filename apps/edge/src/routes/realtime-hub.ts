// CF-native realtime hub — WebSocket fan-out, step 1.
//
//   GET /v1/realtime-hub/conv/:conversationId   — WebSocket upgrade
//
// The client opens one WebSocket per conversation it is viewing. The
// Worker verifies the Supabase JWT (requireSession) and conversation
// membership (resolveConv — RLS-gated), then hands the upgrade off to
// the per-conversation ConvHubDO, which holds the socket and fans
// realtime events out to it.
//
// This route is receive-only for now: the DO does not yet have anything
// pushed into it (Edge fan-in is a later step). It exists so the DO,
// the binding, and the auth path can be stood up and exercised
// independently before the fan-in and the iOS client are wired.

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

  // Hand the upgrade off to the per-conversation DO. X-Hub-User-Id is
  // trusted by the DO because the DO is only reachable through this
  // verified path.
  const stub = c.env.CONV_HUB.get(c.env.CONV_HUB.idFromName(conversationId));
  const headers = new Headers(c.req.raw.headers);
  headers.set('X-Hub-User-Id', userId);
  return stub.fetch(new Request(c.req.raw, { headers }));
});
