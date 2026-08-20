// CF-native realtime hub — WebSocket fan-out, replacing Supabase Realtime.
//
//   GET /v1/realtime-hub/conv/:conversationId   — WebSocket, conv topic
//   GET /v1/realtime-hub/user                   — WebSocket, user topic
//
// A client opens one conv WebSocket per conversation it is viewing and
// one resident user WebSocket.
//
// Auth surface:
//   * conv topic — accepts EITHER a Supabase JWT (membership via resolveConv,
//     RLS-gated) OR a PendingCrew device-grant (`pdg_*`). A device grant only
//     reaches a *crew* conversation: the grant's subject must match the crew's
//     responsible_subject_id (temporary_group_meta). This lets the PendingCrew
//     Mac, which authenticates by device-grant (no Supabase user session),
//     subscribe to its crew's realtime stream.
//   * user topic — JWT-only. A device grant has no user dimension, so it is
//     never widened here; requireSession rejects a `pdg_*` bearer as an invalid
//     JWT. The topic is keyed by the caller's own JWT subject, so a client can
//     only ever reach its own user hub.
//
// Events are pushed into the hubs by the DB-webhook path — see
// routes/realtime-internal.ts. This file is the read side only.

import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient, userClient } from '../lib/supabase';
import { resolveConv } from '../lib/conv-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import { UUID_RE } from '../lib/ids';
import type { AppBindings } from '../types';

export const realtimeHubRoutes = new Hono<AppBindings>();

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

// conv topic — requireSubjectAuth establishes authKind + (deviceGrant | userId)
// without rejecting a device grant the way a bare requireSession would. The
// per-kind membership gate lives in the handler below.
realtimeHubRoutes.get('/conv/:conversationId', requireSubjectAuth(['crew:read']), async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return jsonError(c, 426, 'upgrade_required', {
      message: 'WebSocket upgrade required',
    });
  }

  const conversationId = c.req.param('conversationId');
  if (!UUID_RE.test(conversationId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'bad conversation id' });
  }

  if (c.var.authKind === 'device_grant') {
    // Device-grant callers (PendingCrew Mac) can only reach a *crew*
    // conversation, gated by the crew's responsible subject. A non-crew conv
    // (no temporary_group_meta row) is unreachable this way → 404.
    const dg = c.var.deviceGrant;
    if (!dg) return jsonError(c, 401, 'unauthorized');
    const svc = serviceClient(c.env);
    const { data: meta, error: metaErr } = await svc
      .from('temporary_group_meta')
      .select('conversation_id, responsible_subject_id')
      .eq('conversation_id', conversationId)
      .maybeSingle();
    if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });
    if (!meta) {
      return jsonError(c, 404, 'conversation_not_found', {
        message: 'conversation not found',
      });
    }
    if (dg.subjectId !== meta.responsible_subject_id) {
      return jsonError(c, 403, 'forbidden');
    }
    // The DO only uses X-Hub-User-Id as a label; under a device grant attribute
    // it to the granting user (stable, never null-crashes the DO).
    const hubUserId = dg.grantedByUserId ?? dg.subjectId;
    return handoffToHub(c.env, c.req.raw, `conv:${conversationId}`, hubUserId);
  }

  // Supabase-JWT path — unchanged: resolveConv is the RLS-gated membership
  // check (single-owner convs gate locally, groups fall through to RLS).
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

// user topic — JWT-only (device grants have no user dimension).
realtimeHubRoutes.get('/user', requireSession(), async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return jsonError(c, 426, 'upgrade_required', {
      message: 'WebSocket upgrade required',
    });
  }
  const userId = c.var.userId!;
  return handoffToHub(c.env, c.req.raw, `user:${userId}`, userId);
});
