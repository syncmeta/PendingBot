// T4.3 P1 — Permission Request HTTP layer (spec v2 §10).
//
// Three endpoints (mounted under /v1):
//
//   POST  /v1/permission-requests/:id/decide
//       body { decision: 'approve' | 'reject' }
//       Authenticated user / device-grant. Calls decide_permission_request
//       RPC which enforces:
//         * user_account responsible_subject → only that user
//         * group_account responsible_subject → role IN ('owner','admin')
//       Returns the decided row so the iOS card can re-render without a
//       second fetch.
//
//   PATCH /v1/crews/:crewId/permission-mode
//       body { mode: 'auto' | 'manual' }
//       Crew-level default. Caller must have control over the crew's
//       responsible subject (subject_has_user_access — same gate the
//       crew control routes already use). For group_account subjects we
//       additionally require owner/admin role; for user_account we let
//       the owning user toggle their own crew.
//
//   PATCH /v1/sessions/:sessionId/permission-mode
//       body { mode: 'auto' | 'manual' | null }
//       Session-level override. null clears it (inherit crew default).
//       Same gate as the crew variant — must control the session's
//       responsible subject.
//
// All non-2xx responses go through jsonError → the standard envelope
// { error: { code, message?, detail? } }. New ApiErrorCode values added
// in this branch: permission_request_not_found,
// permission_request_forbidden, permission_request_already_decided.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient, userClient, type SupabaseClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

// schema.ts hasn't been regenerated for this branch's RPC additions yet
// (create_permission_request / decide_permission_request). The main session
// applies db push + types:db. Until then, route through an untyped RPC
// surface for the new functions and keep table access through the typed
// client.
type UntypedRpcClient = {
  rpc: (
    name: string,
    args?: Record<string, unknown>,
  ) => Promise<{ data: unknown; error: { message: string; code?: string } | null }>;
};
function untypedRpc(client: SupabaseClient): UntypedRpcClient {
  return client as unknown as UntypedRpcClient;
}

export const permissionRequestRoutes = new Hono<AppBindings>();
export const crewPermissionModeRoutes = new Hono<AppBindings>();
export const sessionPermissionModeRoutes = new Hono<AppBindings>();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function isUuid(s: string): boolean {
  return UUID_RE.test(s);
}

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

// ────────────────────────────────────────────────────────────────────
// POST /v1/permission-requests/:id/decide
// ────────────────────────────────────────────────────────────────────

const DecideBody = z.object({
  decision: z.enum(['approve', 'reject']),
});

permissionRequestRoutes.post('/:id/decide', requireSubjectAuth(['crew:write']), async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id', { message: 'id must be a uuid' });
  }
  let parsed: z.infer<typeof DecideBody>;
  try {
    parsed = DecideBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Resolve caller user id. Both auth modes converge here: device-grant
  // gives us deviceGrant.grantedByUserId (the user who granted the runner
  // host), supabase JWT gives us userId directly.
  let callerUserId: string;
  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg?.grantedByUserId) {
      return jsonError(c, 403, 'forbidden', {
        message: 'device grant has no granting user — cannot decide on its behalf',
      });
    }
    callerUserId = dg.grantedByUserId;
  } else {
    if (!c.var.userId) return jsonError(c, 401, 'unauthorized');
    callerUserId = c.var.userId;
  }

  // Pre-fetch the row so we can return its current state on success without
  // a second round-trip, and to surface 404 vs 410 cleanly.
  const svc = serviceClient(c.env);
  const { data: existing, error: existingErr } = await svc
    .from('permission_requests')
    .select('id, crew_session_id, responsible_subject_id, requested_action, risk_level, detail, status, requested_at, decided_by_user_id, decided_at')
    .eq('id', id)
    .maybeSingle();
  if (existingErr) return jsonError(c, 500, 'database_error', { detail: existingErr.message });
  if (!existing) return jsonError(c, 404, 'permission_request_not_found');

  // Call the RPC under service-role; it enforces the subject-based ACL
  // internally via the passed caller_user_id (the only authoritative
  // source; we don't trust the client to pass it). The RPC also surfaces
  // 'already decided' as 22023 — we map that to a dedicated code so iOS
  // can clear its pending UI without ambiguity.
  const { error: rpcErr } = await untypedRpc(svc).rpc('decide_permission_request', {
    p_id: id,
    p_decision: parsed.decision,
    p_caller_user_id: callerUserId,
  });
  if (rpcErr) {
    const message = rpcMessage(rpcErr);
    if (/forbidden|mismatch|owner or admin|only subject owner/i.test(message)) {
      return jsonError(c, 403, 'permission_request_forbidden', { message });
    }
    if (/not found/i.test(message)) {
      return jsonError(c, 404, 'permission_request_not_found', { message });
    }
    if (/already decided/i.test(message)) {
      return jsonError(c, 409, 'permission_request_already_decided', {
        message,
        detail: { status: existing.status, decided_at: existing.decided_at },
      });
    }
    if (/invalid|required/i.test(message)) {
      return jsonError(c, 400, 'invalid_body', { message });
    }
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  // Re-read to surface the final state. Cheaper than parsing the RPC's
  // implicit side-effect — we already have the row above; just fetch
  // the freshly-updated columns.
  const { data: updated, error: updatedErr } = await svc
    .from('permission_requests')
    .select('id, crew_session_id, responsible_subject_id, requested_action, risk_level, detail, status, requested_at, decided_by_user_id, decided_at')
    .eq('id', id)
    .maybeSingle();
  if (updatedErr || !updated) {
    return jsonError(c, 500, 'database_error', { detail: updatedErr?.message ?? 'row missing after decide' });
  }

  return c.json({ permissionRequest: updated });
});

// ────────────────────────────────────────────────────────────────────
// PATCH /v1/crews/:crewId/permission-mode
// ────────────────────────────────────────────────────────────────────

const CrewModeBody = z.object({
  mode: z.enum(['auto', 'manual']),
});

/// Helper: verify the caller can change perm-mode for a given
/// responsible_subject. Mirrors the decide_permission_request ACL:
///   * user_account → that user
///   * group_account → owner / admin
async function canControlPermissionMode(
  svc: SupabaseClient,
  responsibleSubjectId: string,
  userId: string,
): Promise<{ ok: boolean; reason?: string }> {
  const { data: subject, error: subjectErr } = await svc
    .from('subjects')
    .select('id, kind, user_id, status')
    .eq('id', responsibleSubjectId)
    .maybeSingle();
  if (subjectErr) return { ok: false, reason: subjectErr.message };
  if (!subject) return { ok: false, reason: 'subject not found' };

  if (subject.kind === 'user_account') {
    if (subject.user_id === userId) return { ok: true };
    return { ok: false, reason: 'only subject owner can change permission mode' };
  }
  if (subject.kind === 'group_account') {
    const { data: hasRole, error: roleErr } = await untypedRpc(svc).rpc('subject_user_has_role', {
      p_subject_id: responsibleSubjectId,
      p_user_id: userId,
      p_roles: ['owner', 'admin'],
    });
    if (roleErr) return { ok: false, reason: rpcMessage(roleErr) };
    if (hasRole === true) return { ok: true };
    return { ok: false, reason: 'owner or admin required' };
  }
  return { ok: false, reason: `unsupported subject kind: ${subject.kind}` };
}

crewPermissionModeRoutes.patch('/:crewId/permission-mode', requireSubjectAuth(['crew:write']), async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  let parsed: z.infer<typeof CrewModeBody>;
  try {
    parsed = CrewModeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  let callerUserId: string;
  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg?.grantedByUserId) return jsonError(c, 403, 'forbidden');
    callerUserId = dg.grantedByUserId;
  } else {
    if (!c.var.userId) return jsonError(c, 401, 'unauthorized');
    callerUserId = c.var.userId;
  }

  const svc = serviceClient(c.env);
  // schema.ts hasn't been regen'd against this branch's migration yet —
  // `permission_mode` isn't on temporary_group_meta in the generated
  // types. Cast .from() result to untyped via `as never` chain so the
  // select / update compiles. Main session regenerates after db push.
  const metaQ = svc
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, status, temporary_kind, permission_mode' as never)
    .eq('conversation_id', crewId)
    .maybeSingle();
  const { data: crewMetaRaw, error: crewErr } = await metaQ;
  if (crewErr) return jsonError(c, 500, 'database_error', { detail: crewErr.message });
  if (!crewMetaRaw) return jsonError(c, 404, 'crew_not_found');
  const crewMeta = crewMetaRaw as unknown as {
    conversation_id: string;
    responsible_subject_id: string;
    status: string;
    temporary_kind: string;
    permission_mode: 'auto' | 'manual';
  };
  if (crewMeta.temporary_kind !== 'crew') {
    return jsonError(c, 400, 'invalid_body', { message: 'target is not a crew conversation' });
  }

  const acl = await canControlPermissionMode(svc, crewMeta.responsible_subject_id, callerUserId);
  if (!acl.ok) {
    return jsonError(c, 403, 'forbidden', { message: acl.reason ?? 'forbidden' });
  }

  const { error: updErr } = await svc
    .from('temporary_group_meta')
    .update({ permission_mode: parsed.mode } as never)
    .eq('conversation_id', crewId);
  if (updErr) return jsonError(c, 500, 'database_error', { detail: updErr.message });

  return c.json({ crewId, permissionMode: parsed.mode });
});

// ────────────────────────────────────────────────────────────────────
// PATCH /v1/sessions/:sessionId/permission-mode
// ────────────────────────────────────────────────────────────────────

// Session override: null clears the field (inherit crew default).
// We accept either explicit `null` or omitted/undefined.
const SessionModeBody = z.object({
  mode: z.union([z.enum(['auto', 'manual']), z.null()]),
});

sessionPermissionModeRoutes.patch('/:sessionId/permission-mode', requireSubjectAuth(['crew:write']), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });
  }
  let parsed: z.infer<typeof SessionModeBody>;
  try {
    parsed = SessionModeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  let callerUserId: string;
  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg?.grantedByUserId) return jsonError(c, 403, 'forbidden');
    callerUserId = dg.grantedByUserId;
  } else {
    if (!c.var.userId) return jsonError(c, 401, 'unauthorized');
    callerUserId = c.var.userId;
  }

  const svc = serviceClient(c.env);
  // Same schema-regen lag as the crew variant — see note above.
  const { data: sessionRowRaw, error: sessionErr } = await svc
    .from('crew_sessions')
    .select('id, responsible_subject_id, permission_mode_override' as never)
    .eq('id', sessionId)
    .maybeSingle();
  if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
  if (!sessionRowRaw) return jsonError(c, 404, 'session_not_found');
  const sessionRow = sessionRowRaw as unknown as {
    id: string;
    responsible_subject_id: string;
    permission_mode_override: 'auto' | 'manual' | null;
  };

  const acl = await canControlPermissionMode(svc, sessionRow.responsible_subject_id, callerUserId);
  if (!acl.ok) {
    return jsonError(c, 403, 'session_forbidden', { message: acl.reason ?? 'forbidden' });
  }

  const { error: updErr } = await svc
    .from('crew_sessions')
    .update({ permission_mode_override: parsed.mode } as never)
    .eq('id', sessionId);
  if (updErr) return jsonError(c, 500, 'database_error', { detail: updErr.message });

  return c.json({
    sessionId,
    permissionModeOverride: parsed.mode,
  });
});

// Re-export userClient just so callers can grep this file and find both
// paths; not used directly yet (all writes here go through service-role
// with caller_user_id passed explicitly).
export { userClient };
