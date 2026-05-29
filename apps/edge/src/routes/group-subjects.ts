// T1.2 — Group account permission matrix HTTP layer (spec v2 §4.3 α).
//
// Mounts under /v1/group-subjects/.
//
// All endpoints require a user-session (supabase JWT). Device-grant tokens
// are intentionally NOT accepted here — grants represent a *runner host*
// acting on behalf of an already-elected subject, not a person managing
// the subject's membership/permissions. The grp_* RPCs key off
// auth.uid() (see migration 20260528083639), so we forward the user JWT
// via userClient.
//
// Routes:
//
//   POST   /v1/group-subjects                       — create a new group
//                                                     account; caller auto-
//                                                     owner. body { display_name }
//                                                     → { subject_id }
//
//   GET    /v1/group-subjects/:id/members           — list members the caller
//                                                     can see (RLS-scoped).
//                                                     → { members: [...] }
//
//   POST   /v1/group-subjects/:id/members           — add a member.
//                                                     owner|admin only.
//                                                     body { user_id }
//
//   DELETE /v1/group-subjects/:id/members/:userId   — remove member.
//                                                     owner|admin; can't kick
//                                                     owner; admin removal
//                                                     requires owner.
//
//   POST   /v1/group-subjects/:id/members/:userId/promote
//                                                   — promote member→admin.
//                                                     owner only.
//
//   POST   /v1/group-subjects/:id/members/:userId/demote
//                                                   — demote admin→member.
//                                                     owner only.
//
//   POST   /v1/group-subjects/:id/transfer          — transfer ownership.
//                                                     owner only. target must
//                                                     already be a member.
//                                                     body { to_user_id }
//
//   POST   /v1/group-subjects/:id/topup             — recharge the subject
//                                                     wallet. owner|admin|member
//                                                     (spec v2 §4.3: 充值全员开放).
//                                                     body { credits }
//                                                     → { balance_credits }
//
// **No withdrawal endpoint** (spec v2 §4.3: 无提现 — 规避「金融服务」性质合规
// 风险, 简化产品). Don't add one without explicit product sign-off.
//
// Authorization is enforced server-side by the SECURITY DEFINER grp_* RPCs
// (see migration 20260528083639_group_account_permission_rpcs.sql). We
// translate the RPC's PostgreSQL error codes into the typed jsonError
// envelope here — never duplicate the role-check logic in the route.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, type SupabaseClient } from '../lib/supabase';
import { jsonError, type ApiErrorCode } from '../lib/http-error';
import type { AppBindings } from '../types';

export const groupSubjectRoutes = new Hono<AppBindings>();
groupSubjectRoutes.use('/*', requireSession());

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function isUuid(s: string): boolean {
  return UUID_RE.test(s);
}

type RpcError = { message: string; code?: string };

// Translate a PostgreSQL ERRCODE raised by a grp_* RPC into our typed HTTP
// envelope. The RPCs use a small, deliberate set of SQLSTATEs:
//   42501 → forbidden (role check failed)
//   28000 → unauthorized (auth.uid() was NULL — JWT not forwarded)
//   P0002 → not_found (subject/target missing)
//   22023 → invalid_state (e.g. "target is owner", non-positive credits)
// Anything else is surfaced as database_error so we don't silently swallow
// unexpected failures.
function rpcErrorToResponse(
  c: Parameters<typeof jsonError>[0],
  err: RpcError,
): Response {
  const code = err.code ?? '';
  const message = err.message ?? 'database error';

  switch (code) {
    case '42501':
      return jsonError(c, 403, 'subject_forbidden', { message });
    case '28000':
      return jsonError(c, 401, 'unauthorized', { message });
    case 'P0002':
      return jsonError(c, 404, 'subject_not_found', { message });
    case '22023':
      return jsonError(c, 409, 'conflict', { message });
    default:
      return jsonError(c, 500, 'database_error', { detail: { code, message } });
  }
}

// Some routes need to return a typed code rather than the generic mapping
// — currently only topup's invalid-credits case, which is an input
// validation problem rather than a state problem.
function rpcErrorToResponseWithOverride(
  c: Parameters<typeof jsonError>[0],
  err: RpcError,
  override: Partial<Record<string, { status: 400 | 401 | 403 | 404 | 409; code: ApiErrorCode }>>,
): Response {
  const sqlstate = err.code ?? '';
  const hit = override[sqlstate];
  if (hit) return jsonError(c, hit.status, hit.code, { message: err.message });
  return rpcErrorToResponse(c, err);
}

function clientForRequest(c: Parameters<typeof jsonError>[0]): SupabaseClient | Response {
  const jwt = c.var.userJwt;
  if (!jwt) return jsonError(c, 401, 'unauthorized');
  return userClient(c.env, jwt);
}

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects — create
// ────────────────────────────────────────────────────────────────────

const CreateBody = z.object({
  display_name: z.string().trim().min(1).max(80),
});

groupSubjectRoutes.post('/', async (c) => {
  let body: z.infer<typeof CreateBody>;
  try {
    body = CreateBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { data, error } = await supa.rpc('grp_create_group_subject', {
    p_display_name: body.display_name,
  });
  if (error) return rpcErrorToResponse(c, error);
  if (typeof data !== 'string') {
    return jsonError(c, 500, 'internal_error', { message: 'rpc returned non-uuid' });
  }
  return c.json({ subject_id: data }, 201);
});

// ────────────────────────────────────────────────────────────────────
// GET /v1/group-subjects/:id/members — list (RLS-scoped read)
// ────────────────────────────────────────────────────────────────────
//
// RLS on group_subject_members already restricts which rows the caller
// sees: members see their own row; owner/admin see all rows in the
// subject (group_subject_members_admin_read policy). That means a
// `member` caller gets a 1-row list — fine for "am I a member?" checks
// and avoids leaking the roster. We do not hide existence of the
// subject — if the caller has no membership row, the list is simply
// empty + we surface 404 to distinguish "subject doesn't exist" from
// "you have no membership row".

groupSubjectRoutes.get('/:id/members', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id', { message: 'id must be a uuid' });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  // Confirm the subject exists (and is a group_account). RLS on subjects
  // allows the caller to see any subject they have access to via
  // group_subject_members; non-members get null.
  const { data: subject, error: subjErr } = await supa
    .from('subjects')
    .select('id, kind, status')
    .eq('id', id)
    .maybeSingle();
  if (subjErr) return jsonError(c, 500, 'database_error', { detail: subjErr.message });
  if (!subject || subject.kind !== 'group_account') {
    return jsonError(c, 404, 'subject_not_found');
  }

  const { data: rows, error } = await supa
    .from('group_subject_members')
    .select('user_id, role, granted_by, granted_at')
    .eq('subject_id', id);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ members: rows ?? [] });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/members — add member
// ────────────────────────────────────────────────────────────────────

const AddMemberBody = z.object({
  user_id: z.string().uuid(),
});

groupSubjectRoutes.post('/:id/members', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id', { message: 'id must be a uuid' });
  }
  let body: z.infer<typeof AddMemberBody>;
  try {
    body = AddMemberBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_add_member', {
    p_group_subject_id: id,
    p_user_id: body.user_id,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// DELETE /v1/group-subjects/:id/members/:userId — remove member
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.delete('/:id/members/:userId', async (c) => {
  const id = c.req.param('id');
  const userId = c.req.param('userId');
  if (!isUuid(id) || !isUuid(userId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_remove_member', {
    p_group_subject_id: id,
    p_user_id: userId,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/members/:userId/promote — owner only
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.post('/:id/members/:userId/promote', async (c) => {
  const id = c.req.param('id');
  const userId = c.req.param('userId');
  if (!isUuid(id) || !isUuid(userId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_promote_to_admin', {
    p_group_subject_id: id,
    p_user_id: userId,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/members/:userId/demote — owner only
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.post('/:id/members/:userId/demote', async (c) => {
  const id = c.req.param('id');
  const userId = c.req.param('userId');
  if (!isUuid(id) || !isUuid(userId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_demote_admin', {
    p_group_subject_id: id,
    p_user_id: userId,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/transfer — owner only
// ────────────────────────────────────────────────────────────────────

const TransferBody = z.object({
  to_user_id: z.string().uuid(),
});

groupSubjectRoutes.post('/:id/transfer', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id');
  }
  let body: z.infer<typeof TransferBody>;
  try {
    body = TransferBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_transfer_ownership', {
    p_group_subject_id: id,
    p_to_user_id: body.to_user_id,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/topup — owner|admin|member (spec v2 §4.3)
// ────────────────────────────────────────────────────────────────────
//
// This is the *accounting* hook — real-money flows (IAP / billing
// webhook) happen out-of-band and the webhook handler calls the same
// RPC under service_role. Exposing it to authenticated callers preserves
// the "self-serve topup" UX path for the future.

const TopupBody = z.object({
  credits: z.number().int().positive(),
});

groupSubjectRoutes.post('/:id/topup', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id');
  }
  let body: z.infer<typeof TopupBody>;
  try {
    body = TopupBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { data, error } = await supa.rpc('grp_topup_wallet', {
    p_group_subject_id: id,
    p_credits: body.credits,
  });
  if (error) {
    // 22023 from grp_topup_wallet specifically means "credits must be
    // positive" — surface as invalid_body rather than the generic
    // conflict (which is appropriate for state errors elsewhere).
    return rpcErrorToResponseWithOverride(c, error, {
      '22023': { status: 400, code: 'invalid_body' },
    });
  }
  if (typeof data !== 'number') {
    return jsonError(c, 500, 'internal_error', { message: 'rpc returned non-numeric balance' });
  }
  return c.json({ balance_credits: data });
});
