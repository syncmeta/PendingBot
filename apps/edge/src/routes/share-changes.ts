// Phase 2 cross-subject share-change endpoints (spec v2 §7.3 rule 4).
//
// Companion to /v1/crews/:crewId/share-changes (which *creates* the
// proposal). These endpoints let each involved subject's owner/admin
// vote, and list the proposals the caller still has to weigh in on.
//
//   POST /v1/share-changes/:id/decision    — approve|reject as a subject
//   GET  /v1/share-changes/pending         — list pending for the caller
//
// `approved` calls go through the DB RPC `crew_approve_share_change`,
// which also handles the "all required subjects approved → flip status
// to 'approved'" transition.
//
// `rejected` calls bypass the RPC — the RPC stub only knows the affirm
// path. We service-role update the row to status='rejected', recording
// the rejecting subject in `approvals[subjectId]` with a `decision:
// 'rejected'` marker so the audit trail survives.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

export const shareChangesRoutes = new Hono<AppBindings>();
shareChangesRoutes.use('*', requireSession());

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

function rpcErrorCode(err: unknown): string | null {
  if (err && typeof err === 'object' && typeof (err as { code?: unknown }).code === 'string') {
    return (err as { code: string }).code;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────
// POST /v1/share-changes/:id/decision
// ─────────────────────────────────────────────────────────────

const DecisionBody = z.object({
  decision: z.enum(['approved', 'rejected']),
  asSubjectId: z.string().uuid(),
  note: z.string().trim().max(2_000).optional(),
});

shareChangesRoutes.post('/:id/decision', async (c) => {
  const changeId = c.req.param('id');
  if (!isUuid(changeId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'id must be a uuid' });
  }
  let parsed: z.infer<typeof DecisionBody>;
  try {
    parsed = DecisionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  const supaUser = userClient(c.env, userJwt);

  if (parsed.decision === 'approved') {
    const { data: status, error } = await supaUser.rpc('crew_approve_share_change', {
      p_change_id: changeId,
      p_subject_id: parsed.asSubjectId,
    });
    if (error) {
      const code = rpcErrorCode(error);
      const message = rpcMessage(error);
      if (code === '28000') return jsonError(c, 401, 'unauthorized', { message });
      if (code === '42501' || /forbidden|cannot act for subject/i.test(message)) {
        return jsonError(c, 403, 'crew_share_change_forbidden', { message });
      }
      if (code === 'P0002' || /change not found/i.test(message)) {
        return jsonError(c, 404, 'not_found', { message });
      }
      if (code === '22023' || /already decided|not in required/i.test(message)) {
        return jsonError(c, 409, 'conflict', { message });
      }
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    // Re-fetch to surface the full approvals object.
    const svc = serviceClient(c.env);
    const { data: row, error: rowErr } = await svc
      .from('crew_pending_share_changes')
      .select('status, approvals')
      .eq('id', changeId)
      .maybeSingle();
    if (rowErr) return jsonError(c, 500, 'database_error', { detail: rowErr.message });
    return c.json({
      status: row?.status ?? status ?? 'pending',
      approvals: row?.approvals ?? {},
    });
  }

  // Rejection path — the DB RPC doesn't cover it, so we do an explicit
  // service-role update after verifying the caller can act for the
  // asSubjectId AND that subject is in the required-approvals set.
  const svc = serviceClient(c.env);
  const { data: row, error: rowErr } = await svc
    .from('crew_pending_share_changes')
    .select('id, status, approvals, requires_subject_approvals')
    .eq('id', changeId)
    .maybeSingle();
  if (rowErr) return jsonError(c, 500, 'database_error', { detail: rowErr.message });
  if (!row) return jsonError(c, 404, 'not_found');
  if (row.status !== 'pending') {
    return jsonError(c, 409, 'conflict', {
      message: `change already decided (${row.status})`,
      detail: { status: row.status },
    });
  }
  const required = Array.isArray(row.requires_subject_approvals) ? row.requires_subject_approvals : [];
  if (!required.includes(parsed.asSubjectId)) {
    return jsonError(c, 400, 'crew_share_invalid', {
      message: 'asSubjectId is not in requires_subject_approvals',
    });
  }

  // Auth check: caller must be owner/admin on asSubjectId. We lean on
  // the DB-side `subject_user_has_role` RPC so the predicate stays in
  // one place.
  const { data: hasRole, error: roleErr } = await supaUser.rpc('subject_user_has_role', {
    p_subject_id: parsed.asSubjectId,
    p_user_id: userId,
    p_roles: ['owner', 'admin'],
  });
  if (roleErr) return jsonError(c, 500, 'database_error', { detail: roleErr.message });
  if (hasRole !== true) return jsonError(c, 403, 'crew_share_change_forbidden');

  // Record the rejection in approvals[subjectId] for audit, then flip
  // status to 'rejected' atomically (well — supabase-js doesn't expose
  // a transaction, but a single update is row-atomic at the postgres
  // level which is what we actually need here).
  const approvals = (row.approvals && typeof row.approvals === 'object' && !Array.isArray(row.approvals)
    ? row.approvals
    : {}) as Record<string, unknown>;
  approvals[parsed.asSubjectId] = {
    decision: 'rejected',
    by_user_id: userId,
    at: new Date().toISOString(),
    ...(parsed.note ? { note: parsed.note } : {}),
  };
  const { error: updateErr } = await svc
    .from('crew_pending_share_changes')
    .update({
      status: 'rejected',
      approvals: approvals as Json,
      decided_at: new Date().toISOString(),
    })
    .eq('id', changeId)
    .eq('status', 'pending');
  if (updateErr) return jsonError(c, 500, 'database_error', { detail: updateErr.message });

  return c.json({ status: 'rejected', approvals });
});

// ─────────────────────────────────────────────────────────────
// GET /v1/share-changes/pending — proposals the caller can still decide
//
// Returns pending rows where the caller is owner/admin of at least one
// subject in `requires_subject_approvals` AND hasn't recorded a
// decision yet. Joins the crew title for display.
// ─────────────────────────────────────────────────────────────

shareChangesRoutes.get('/pending', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  const supa = serviceClient(c.env);

  // Subjects the caller can act for (owner/admin only — members can't
  // approve a share change for their group account).
  const actableSubjectIds = new Set<string>();
  {
    const { data, error } = await supa
      .from('subjects')
      .select('id')
      .eq('kind', 'user_account')
      .eq('user_id', userId)
      .eq('status', 'active')
      .maybeSingle();
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    if (data?.id) actableSubjectIds.add(data.id);
  }
  {
    const { data, error } = await supa
      .from('group_subject_members')
      .select('subject_id')
      .eq('user_id', userId)
      .in('role', ['owner', 'admin']);
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    for (const row of data ?? []) {
      if (typeof row.subject_id === 'string') actableSubjectIds.add(row.subject_id);
    }
  }
  if (actableSubjectIds.size === 0) {
    return c.json({ pending: [] });
  }

  // Pull pending rows where requires_subject_approvals overlaps with
  // actableSubjectIds. PostgREST doesn't have a direct array-overlap
  // operator we can chain cleanly here without raw SQL, so we pull all
  // pending rows and filter in-process. Pending proposals should be
  // sparse (handful at most per active crew), so this is fine.
  const { data: rows, error } = await supa
    .from('crew_pending_share_changes')
    .select('id, crew_id, proposed_by, proposal_payload, approvals, requires_subject_approvals, created_at')
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });

  type PendingRow = {
    id: string;
    crew_id: string;
    proposed_by: string | null;
    proposal_payload: Json;
    approvals: Json;
    requires_subject_approvals: string[];
    created_at: string;
  };
  type WithMatch = PendingRow & { my_subject_id: string };
  const matched: WithMatch[] = [];
  for (const row of (rows ?? []) as PendingRow[]) {
    const required = Array.isArray(row.requires_subject_approvals) ? row.requires_subject_approvals : [];
    const approvals = (row.approvals && typeof row.approvals === 'object' && !Array.isArray(row.approvals)
      ? row.approvals
      : {}) as Record<string, unknown>;
    // Skip if the caller's actable subjects all already recorded a decision.
    const pendingForCaller = required.find(
      (s) => actableSubjectIds.has(s) && !(s in approvals),
    );
    if (pendingForCaller) {
      matched.push({ ...row, my_subject_id: pendingForCaller });
    }
  }

  if (matched.length === 0) {
    return c.json({ pending: [] });
  }

  // Hydrate crew titles in one batch.
  const crewIds = Array.from(new Set(matched.map((r) => r.crew_id)));
  const titlesById = new Map<string, string>();
  {
    const { data, error: titleErr } = await supa
      .from('temporary_group_meta')
      .select('conversation_id, title')
      .in('conversation_id', crewIds);
    if (titleErr) return jsonError(c, 500, 'database_error', { detail: titleErr.message });
    for (const row of data ?? []) {
      titlesById.set(row.conversation_id, row.title ?? '机组');
    }
  }

  return c.json({
    pending: matched.map((row) => ({
      id: row.id,
      crewId: row.crew_id,
      crewTitle: titlesById.get(row.crew_id) ?? '机组',
      proposedBy: row.proposed_by,
      proposalPayload: row.proposal_payload,
      createdAt: row.created_at,
      mySubjectId: row.my_subject_id,
    })),
  });
});
