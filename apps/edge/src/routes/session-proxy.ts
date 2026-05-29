// T4.5 P0 — Cross-device session proxy HTTP layer (spec v2 §8.2 + §9.6).
//
//   GET /v1/sessions/:sessionId/proxy/connect   — WebSocket upgrade
//
// A client (viewer or runner) opens one WebSocket per session it wants to
// watch / remote-control. The worker authenticates the upgrade HERE — same
// device-grant-vs-JWT shape the rest of the crew routes use — resolves the
// session row, gates the caller against the session's responsible subject,
// then forwards the upgrade to the session's SessionProxyDO with the
// trusted, server-derived facts stamped on headers. The DO never re-parses
// a bearer token; it trusts the headers because only the worker can reach
// the DO's fetch.
//
// Role resolution:
//   * runner — a device grant carrying the `runner:write` scope whose
//     subject matches the session's responsible subject. This is the
//     PendingCrew Mac (or v1.1 Fly machine) actually running the agent.
//   * viewer — anyone else who can see the session:
//       - a device grant for the session's subject (crew:read), OR
//       - a Supabase-JWT user who can view the crew (can_view_temporary_group).
//
// The client signals its intent with ?role=runner|viewer; we enforce that
// the chosen role is one the caller is actually authorized for (a viewer
// asking for runner without runner:write is rejected, and vice-versa we
// never silently downgrade — the client asked for runner because it IS one).
// Default (no ?role) → viewer.

import { Hono } from 'hono';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const sessionProxyRoutes = new Hono<AppBindings>();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function isUuid(s: string): boolean {
  return UUID_RE.test(s);
}

// requireSubjectAuth([]) — no scope requirement at the middleware level; the
// per-role scope check happens in the handler (runner needs runner:write,
// viewer device-grant needs crew:read). An empty array just establishes
// authKind + deviceGrant/userId without rejecting a runner grant that lacks
// crew:read.
sessionProxyRoutes.get('/:sessionId/proxy/connect', requireSubjectAuth([]), async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket') {
    return jsonError(c, 426, 'upgrade_required', { message: 'WebSocket upgrade required' });
  }
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });
  }

  const requestedRole = (c.req.query('role') ?? 'viewer').toLowerCase();
  if (requestedRole !== 'viewer' && requestedRole !== 'runner') {
    return jsonError(c, 400, 'invalid_query', { message: 'role must be viewer|runner' });
  }

  // Resolve the session row + its responsible subject (the ACL anchor).
  const svc = serviceClient(c.env);
  const { data: sessionRow, error: sessionErr } = await svc
    .from('crew_sessions')
    .select('id, crew_conversation_id, responsible_subject_id, runner_host_id, runner_kind, status')
    .eq('id', sessionId)
    .maybeSingle();
  if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
  if (!sessionRow) return jsonError(c, 404, 'session_not_found');

  let resolvedRole: 'viewer' | 'runner';
  let subjectId: string | null = null;
  let userId: string | null = null;

  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg) return jsonError(c, 401, 'unauthorized');
    // Every device grant is scoped to a subject; the grant's subject must
    // own this session regardless of role.
    if (dg.subjectId !== sessionRow.responsible_subject_id) {
      return jsonError(c, 403, 'session_forbidden');
    }
    subjectId = dg.subjectId;
    userId = dg.grantedByUserId;

    if (requestedRole === 'runner') {
      // Runner role demands the runner:write scope (only pendingcrew_runner
      // / pendingcrew_control grants carry it).
      if (!dg.scopes.includes('runner:write')) {
        return jsonError(c, 403, 'forbidden', {
          message: 'runner role requires a device grant with runner:write scope',
        });
      }
      resolvedRole = 'runner';
    } else {
      // Viewer role over a device grant needs crew:read. A pure runner grant
      // (runner:* only) connecting as a viewer is unusual but allowed if it
      // happens to also carry crew:read; otherwise reject.
      if (!dg.scopes.includes('crew:read')) {
        return jsonError(c, 403, 'forbidden', {
          message: 'viewer role requires a device grant with crew:read scope',
        });
      }
      resolvedRole = 'viewer';
    }
  } else {
    // Supabase-JWT path — humans can only be viewers (a runner is always a
    // device-granted host, never a logged-in human session).
    if (requestedRole === 'runner') {
      return jsonError(c, 403, 'forbidden', {
        message: 'runner role requires a device grant, not a user session',
      });
    }
    const uid = c.var.userId;
    if (!uid) return jsonError(c, 401, 'unauthorized');
    const { data: canView, error: canViewErr } = await svc.rpc('can_view_temporary_group', {
      p_conversation_id: sessionRow.crew_conversation_id,
      p_user_id: uid,
    });
    if (canViewErr) return jsonError(c, 500, 'database_error', { detail: canViewErr.message });
    if (canView !== true) return jsonError(c, 403, 'session_forbidden');
    resolvedRole = 'viewer';
    userId = uid;
  }

  // Forward the upgrade to the session's DO with the trusted facts stamped
  // on. idFromName(sessionId) → one DO instance per session.
  const stub = c.env.SESSION_PROXY_DO.get(c.env.SESSION_PROXY_DO.idFromName(sessionId));
  const headers = new Headers(c.req.raw.headers);
  headers.set('X-Proxy-Role', resolvedRole);
  headers.set('X-Proxy-Session-Id', sessionId);
  if (subjectId) headers.set('X-Proxy-Subject', subjectId);
  if (userId) headers.set('X-Proxy-User-Id', userId);
  return stub.fetch(new Request(c.req.raw, { headers }));
});
