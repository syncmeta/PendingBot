// Phase 2 crew endpoints (spec v2 §6 + §7 + §11).
//
// Mounted at `/v1/crews`. Distinct from the legacy `/v1/crew` (singular)
// surface in `crew.ts` — that one drives the older `open_crew_conv` /
// `create_child_crew_inheriting_responsibility` RPCs (pre-T2.x). This
// file wraps the Phase 2 RPC family:
//
//   create_crew_with_captain   — POST /v1/crews
//   crew_attach_as_child       — POST /v1/crews/:crewId/attach-parent
//   crew_propose_share_change  — POST /v1/crews/:crewId/share-changes
//
// plus the read-side endpoints:
//
//   GET /v1/crews              — list crews caller can see
//   GET /v1/crews/:crewId      — crew detail (parents/children/shares/captain)
//
// Accepts BOTH a supabase user JWT (`requireSession` path) and a
// PendingCrew device grant (`pdg_*`). PendingCrew is the primary consumer
// of this surface and authenticates with a device grant — it has no user
// JWT. JWT callers go through `userClient` so RLS / RPC `auth.uid()`
// reflect them; device-grant callers go through `serviceClient` and pass
// the grant's `grantedByUserId` as the explicit actor (`p_actor_user_id`),
// mirroring the legacy `/v1/crew/*` convention (`open_crew_conv_for_subject`).

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSubjectAuth, hasDeviceScope } from '../lib/device-grants';
import { serviceClient, userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

export const crewsRoutes = new Hono<AppBindings>();
// `subject:read` is the floor every PendingCrew grant carries; per-handler
// checks below additionally require `crew:write` for the mutating routes.
crewsRoutes.use('*', requireSubjectAuth(['crew:read']));

// Resolve the acting supabase user id regardless of auth kind. JWT callers
// → their own uid; device-grant callers → the user who approved the grant
// on iOS (`grantedByUserId`). Returns a 403 Response if a device grant is
// missing its approving user (should never happen for an active grant).
function actingUserId(
  c: Parameters<typeof jsonError>[0],
): { userId: string } | { error: Response } {
  if (c.var.authKind === 'device_grant') {
    const uid = c.var.deviceGrant?.grantedByUserId;
    if (!uid) return { error: jsonError(c, 403, 'forbidden') };
    return { userId: uid };
  }
  return { userId: c.var.userId! };
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

// Map common pg SQLSTATEs that the Phase 2 RPCs raise.
//   28000 = authentication required (we already gate with
//           requireSession, so this only fires if the JWT was scrubbed
//           server-side — treat as 401).
//   42501 = forbidden (RAISE EXCEPTION ... USING ERRCODE='42501').
//   22023 = invalid_parameter_value (range / enum errors).
//   P0002 = no_data_found (crew / proposal lookup miss).
//   23514 = check_violation (cycle-guard trigger).
function rpcErrorCode(err: unknown): string | null {
  if (err && typeof err === 'object' && typeof (err as { code?: unknown }).code === 'string') {
    return (err as { code: string }).code;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────
// POST /v1/crews — create a crew + choose a captain
// ─────────────────────────────────────────────────────────────

const CaptainBody = z.discriminatedUnion('source', [
  z.object({
    source: z.literal('reuse_bot'),
    botId: z.string().uuid(),
  }),
  z.object({
    source: z.literal('system_generated'),
    templateName: z.string().trim().max(80).optional(),
  }),
]);

const CreateCrewBody = z.object({
  responsibleSubjectId: z.string().uuid(),
  title: z.string().trim().max(80).optional(),   // optional/auto — empty allowed
  workingDirectory: z.string().trim().max(2048).optional(),
  machineId: z.string().uuid().optional(),        // null/absent = local
  captain: CaptainBody,
});

crewsRoutes.post('/', async (c) => {
  let parsed: z.infer<typeof CreateCrewBody>;
  try {
    parsed = CreateCrewBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Device grants may only create crews for the subject they represent;
  // and the mutating path requires the crew:write scope.
  let actorUserId: string | undefined;
  if (c.var.authKind === 'device_grant') {
    if (!hasDeviceScope(c, 'crew:write')) return jsonError(c, 403, 'forbidden');
    if (parsed.responsibleSubjectId !== c.var.deviceGrant?.subjectId) {
      return jsonError(c, 403, 'forbidden');
    }
    const actor = actingUserId(c);
    if ('error' in actor) return actor.error;
    actorUserId = actor.userId;
  }

  // JWT callers run through userClient (auth.uid() drives the RPC);
  // device-grant callers run through serviceClient and pass the verified
  // actor explicitly (auth.uid() is null there, so the RPC's COALESCE
  // picks p_actor_user_id).
  const supa = actorUserId
    ? serviceClient(c.env)
    : userClient(c.env, c.var.userJwt!);

  const captain = parsed.captain;
  const { data: convId, error } = await supa.rpc('create_crew_with_captain', {
    p_responsible_subject_id: parsed.responsibleSubjectId,
    p_title: parsed.title?.trim() || '',
    p_working_directory: parsed.workingDirectory ?? undefined,
    p_captain_source: captain.source,
    p_captain_bot_id: captain.source === 'reuse_bot' ? captain.botId : undefined,
    p_captain_template_name: captain.source === 'system_generated' ? (captain.templateName ?? undefined) : undefined,
    p_actor_user_id: actorUserId ?? undefined,
    p_machine_id: parsed.machineId ?? undefined,
  });
  if (error) {
    const code = rpcErrorCode(error);
    const message = rpcMessage(error);
    if (code === '28000' || /authentication required/i.test(message)) {
      return jsonError(c, 401, 'unauthorized', { message });
    }
    if (code === '42501' || /forbidden/i.test(message)) {
      return jsonError(c, 403, 'forbidden', { message });
    }
    if (code === '22023' || /invalid|required/i.test(message)) {
      return jsonError(c, 400, 'invalid_body', { message });
    }
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  // Look the captain back up — the RPC only returns the conv id, but
  // the client needs the captain bot id so it can immediately show the
  // captain card / wire chat composer.
  const { data: meta, error: metaErr } = await supa
    .from('temporary_group_meta')
    .select('captain_bot_id')
    .eq('conversation_id', convId as string)
    .maybeSingle();
  if (metaErr) {
    return jsonError(c, 500, 'database_error', { detail: metaErr.message });
  }
  return c.json({
    crewId: convId as string,
    captainBotId: meta?.captain_bot_id ?? null,
  });
});

// ─────────────────────────────────────────────────────────────
// POST /v1/crews/:crewId/attach-parent — attach this crew under a parent
// ─────────────────────────────────────────────────────────────

const AttachParentBody = z.object({
  parentCrewId: z.string().uuid(),
  // bps the *child keeps* — strictly 1..9999 per spec v2 §7.3 rule 1;
  // the RPC computes parent share = 10000 - childKeepsBps.
  childKeepsBps: z.number().int().min(1).max(9999),
});

crewsRoutes.post('/:crewId/attach-parent', async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  let parsed: z.infer<typeof AttachParentBody>;
  try {
    parsed = AttachParentBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  let actorUserId: string | undefined;
  if (c.var.authKind === 'device_grant') {
    if (!hasDeviceScope(c, 'crew:write')) return jsonError(c, 403, 'forbidden');
    const actor = actingUserId(c);
    if ('error' in actor) return actor.error;
    actorUserId = actor.userId;
  }
  const supa = actorUserId
    ? serviceClient(c.env)
    : userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('crew_attach_as_child', {
    p_child: crewId,
    p_parent: parsed.parentCrewId,
    p_child_keeps_bps: parsed.childKeepsBps,
    p_actor_user_id: actorUserId ?? undefined,
  });
  if (error) {
    const code = rpcErrorCode(error);
    const message = rpcMessage(error);
    // Cycle guard trigger raises 23514 (check_violation) with a message
    // containing "cycle". Edge cases (e.g. same-crew parent/child) come
    // through as 22023 via the RPC's explicit check.
    if (code === '23514' || /cycle/i.test(message)) {
      return jsonError(c, 409, 'crew_cycle', { message });
    }
    if (code === '42501' || /forbidden/i.test(message)) {
      return jsonError(c, 403, 'crew_attach_forbidden', { message });
    }
    if (code === '22023' || /must be in|invalid|required|child cannot equal parent/i.test(message)) {
      return jsonError(c, 400, 'crew_share_invalid', { message });
    }
    if (code === 'P0002' || /not found/i.test(message)) {
      return jsonError(c, 404, 'crew_not_found', { message });
    }
    if (code === '28000' || /authentication required/i.test(message)) {
      return jsonError(c, 401, 'unauthorized', { message });
    }
    return jsonError(c, 500, 'database_error', { detail: message });
  }
  return c.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────
// GET /v1/crews — list crews caller can see
//
// Caller sees crews whose responsible_subject_id is one of:
//   * the caller's user_account subject
//   * any group_subject where the caller is owner/admin/member
//
// Note: a crew is *also* visible if the caller is a temporary_group_members
// row on it (e.g. peer collaboration), but we lean on the simpler
// responsibility-subject filter here. The detail endpoint (GET
// /v1/crews/:crewId) double-checks via can_view_temporary_group, which
// is the canonical visibility predicate, so anything missing here can
// still be opened via a direct link.
// ─────────────────────────────────────────────────────────────

crewsRoutes.get('/', async (c) => {
  const actor = actingUserId(c);
  if ('error' in actor) return actor.error;
  const userId = actor.userId;
  // Device grants have no JWT → use service role for the post-filtered
  // read (visibility is already encoded by the accessibleSubjectIds set).
  const supa = c.var.authKind === 'device_grant'
    ? serviceClient(c.env)
    : userClient(c.env, c.var.userJwt!);

  const subjectIds = await accessibleSubjectIds(c, userId, ['owner', 'admin', 'member']);
  if (subjectIds.error) return subjectIds.error;
  if (subjectIds.ids.length === 0) {
    return c.json({ crews: [] });
  }

  const { data: rows, error } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, captain_bot_id, runtime_location, machine_id, title, created_at, updated_at, status')
    .eq('temporary_kind', 'crew')
    .in('responsible_subject_id', subjectIds.ids)
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const crews = (rows ?? []).map((row) => ({
    id: row.conversation_id,
    title: row.title ?? '机组',
    responsibleSubjectId: row.responsible_subject_id,
    runtimeLocation: row.runtime_location,
    machineId: row.machine_id,
    captainBotId: row.captain_bot_id,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));
  return c.json({ crews });
});

// ─────────────────────────────────────────────────────────────
// GET /v1/crews/:crewId — crew detail
//
// Gated by can_view_temporary_group(crew_id, auth.uid()), the canonical
// "may caller see this crew" predicate. Returns the crew row plus its
// parent/child crew links (with the parent's share bps on each edge),
// the resolved responsibility shares (with subject display_name), and
// the captain bot if any.
// ─────────────────────────────────────────────────────────────

crewsRoutes.get('/:crewId', async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  const actor = actingUserId(c);
  if ('error' in actor) return actor.error;
  const userId = actor.userId;
  // can_view_temporary_group takes the user id explicitly, so it's safe
  // to invoke via service role for device grants (no JWT available).
  const supaUser = c.var.authKind === 'device_grant'
    ? serviceClient(c.env)
    : userClient(c.env, c.var.userJwt!);

  const { data: canView, error: canViewErr } = await supaUser.rpc('can_view_temporary_group', {
    p_conversation_id: crewId,
    p_user_id: userId,
  });
  if (canViewErr) return jsonError(c, 500, 'database_error', { detail: canViewErr.message });
  if (canView !== true) return jsonError(c, 404, 'crew_not_found');

  // Past the visibility check we use service-role for the fan-out — RLS
  // on crew_parent_links / crew_responsibility_shares would otherwise
  // require the caller to be a member of every linked crew, which isn't
  // the contract we want for the detail page.
  const svc = serviceClient(c.env);
  const { data: crewRow, error: crewErr } = await svc
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, captain_bot_id, runtime_location, working_directory, title, created_at, updated_at, status')
    .eq('conversation_id', crewId)
    .eq('temporary_kind', 'crew')
    .maybeSingle();
  if (crewErr) return jsonError(c, 500, 'database_error', { detail: crewErr.message });
  if (!crewRow) return jsonError(c, 404, 'crew_not_found');

  // Parents: edges where THIS crew is the child.
  const { data: parentEdges, error: parentErr } = await svc
    .from('crew_parent_links')
    .select('parent_crew_id, child_share_bps')
    .eq('child_crew_id', crewId);
  if (parentErr) return jsonError(c, 500, 'database_error', { detail: parentErr.message });

  // Children: edges where THIS crew is the parent.
  const { data: childEdges, error: childErr } = await svc
    .from('crew_parent_links')
    .select('child_crew_id, child_share_bps')
    .eq('parent_crew_id', crewId);
  if (childErr) return jsonError(c, 500, 'database_error', { detail: childErr.message });

  // Hydrate linked crew titles in one batch.
  const linkedCrewIds = Array.from(new Set([
    ...((parentEdges ?? []).map((e) => e.parent_crew_id)),
    ...((childEdges ?? []).map((e) => e.child_crew_id)),
  ]));
  const titlesById = new Map<string, string>();
  if (linkedCrewIds.length > 0) {
    const { data: titleRows, error: titleErr } = await svc
      .from('temporary_group_meta')
      .select('conversation_id, title')
      .in('conversation_id', linkedCrewIds);
    if (titleErr) return jsonError(c, 500, 'database_error', { detail: titleErr.message });
    for (const row of titleRows ?? []) {
      titlesById.set(row.conversation_id, row.title ?? '机组');
    }
  }

  // Responsibility shares + subject display info.
  const { data: shareRows, error: shareErr } = await svc
    .from('crew_responsibility_shares')
    .select('subject_id, share_bps, is_tiebreaker')
    .eq('crew_conversation_id', crewId);
  if (shareErr) return jsonError(c, 500, 'database_error', { detail: shareErr.message });
  const subjectIds = Array.from(new Set((shareRows ?? []).map((r) => r.subject_id)));
  const subjectInfo = new Map<string, { displayName: string; kind: string }>();
  if (subjectIds.length > 0) {
    const { data: subjRows, error: subjErr } = await svc
      .from('subjects')
      .select('id, display_name, kind')
      .in('id', subjectIds);
    if (subjErr) return jsonError(c, 500, 'database_error', { detail: subjErr.message });
    for (const row of subjRows ?? []) {
      subjectInfo.set(row.id, {
        displayName: row.display_name,
        kind: row.kind,
      });
    }
  }

  // Captain bot display name.
  let captain: { botId: string; displayName: string } | null = null;
  if (crewRow.captain_bot_id) {
    const { data: botRow, error: botErr } = await svc
      .from('bots')
      .select('id, display_name')
      .eq('id', crewRow.captain_bot_id)
      .maybeSingle();
    if (botErr) return jsonError(c, 500, 'database_error', { detail: botErr.message });
    if (botRow) {
      captain = {
        botId: botRow.id,
        displayName: botRow.display_name ?? '机长',
      };
    }
  }

  return c.json({
    crew: {
      id: crewRow.conversation_id,
      title: crewRow.title ?? '机组',
      responsibleSubjectId: crewRow.responsible_subject_id,
      runtimeLocation: crewRow.runtime_location,
      workingDirectory: crewRow.working_directory,
      captainBotId: crewRow.captain_bot_id,
      status: crewRow.status,
      createdAt: crewRow.created_at,
      updatedAt: crewRow.updated_at,
    },
    parents: (parentEdges ?? []).map((edge) => ({
      crewId: edge.parent_crew_id,
      title: titlesById.get(edge.parent_crew_id) ?? '机组',
      childShareBps: edge.child_share_bps,
    })),
    children: (childEdges ?? []).map((edge) => ({
      crewId: edge.child_crew_id,
      title: titlesById.get(edge.child_crew_id) ?? '机组',
      childShareBps: edge.child_share_bps,
    })),
    shares: (shareRows ?? []).map((row) => {
      const info = subjectInfo.get(row.subject_id);
      return {
        subjectId: row.subject_id,
        shareBps: row.share_bps,
        isTiebreaker: row.is_tiebreaker,
        displayName: info?.displayName ?? '',
        kind: info?.kind ?? 'unknown',
      };
    }),
    captain,
  });
});

// ─────────────────────────────────────────────────────────────
// POST /v1/crews/:crewId/share-changes — propose new responsibility shares
//
// Spec v2 §7.3 rule 4 — cross-subject changes require approval from
// every involved subject. We compute the required-approval set here as
// the union of subjects in the proposed shares and the subjects that
// currently hold shares (so a subject that's being *removed* still
// gets a vote). The DB stub records the proposal; approvals come in
// through POST /v1/share-changes/:id/decision.
// ─────────────────────────────────────────────────────────────

const ProposedShare = z.object({
  subjectId: z.string().uuid(),
  shareBps: z.number().int().min(1).max(9999),
});

const ProposeShareChangeBody = z.object({
  proposedShares: z.array(ProposedShare).min(1).max(64),
  reason: z.string().trim().max(2_000).optional(),
});

crewsRoutes.post('/:crewId/share-changes', async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  let parsed: z.infer<typeof ProposeShareChangeBody>;
  try {
    parsed = ProposeShareChangeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  // Sum must add up to 10_000 (spec v2 §7.3 — total responsibility is
  // always exactly 100%). The DB recompute would normalise, but for a
  // *proposal* we want the human-entered numbers to be coherent.
  const sum = parsed.proposedShares.reduce((acc, s) => acc + s.shareBps, 0);
  if (sum !== 10_000) {
    return jsonError(c, 400, 'crew_share_invalid', {
      message: 'proposedShares.shareBps must sum to 10000',
      detail: { sum },
    });
  }
  // No duplicate subject_id in the proposed set.
  const proposedSubjects = new Set<string>();
  for (const s of parsed.proposedShares) {
    if (proposedSubjects.has(s.subjectId)) {
      return jsonError(c, 400, 'crew_share_invalid', {
        message: 'duplicate subjectId in proposedShares',
        detail: { subjectId: s.subjectId },
      });
    }
    proposedSubjects.add(s.subjectId);
  }

  let actorUserId: string | undefined;
  if (c.var.authKind === 'device_grant') {
    if (!hasDeviceScope(c, 'crew:write')) return jsonError(c, 403, 'forbidden');
    const actor = actingUserId(c);
    if ('error' in actor) return actor.error;
    actorUserId = actor.userId;
  }
  const supaUser = actorUserId
    ? serviceClient(c.env)
    : userClient(c.env, c.var.userJwt!);

  // Pull current shares so we can union the "subjects who must approve".
  // We use service-role here because the caller may legitimately be
  // proposing on a crew where they only have visibility (member) — RLS
  // on crew_responsibility_shares is read-only and could otherwise
  // return an empty set silently.
  const svc = serviceClient(c.env);
  const { data: currentShares, error: curErr } = await svc
    .from('crew_responsibility_shares')
    .select('subject_id')
    .eq('crew_conversation_id', crewId);
  if (curErr) return jsonError(c, 500, 'database_error', { detail: curErr.message });

  const requiredApprovals = new Set<string>(proposedSubjects);
  for (const row of currentShares ?? []) {
    requiredApprovals.add(row.subject_id);
  }
  const requiredApprovalsArr = Array.from(requiredApprovals);

  const payload: Record<string, unknown> = {
    proposed_shares: parsed.proposedShares.map((s) => ({
      subject_id: s.subjectId,
      share_bps: s.shareBps,
    })),
  };
  if (parsed.reason) payload.reason = parsed.reason;

  const { data: changeId, error } = await supaUser.rpc('crew_propose_share_change', {
    p_crew_id: crewId,
    p_proposal_payload: payload as Json,
    p_requires_subject_approvals: requiredApprovalsArr,
    p_actor_user_id: actorUserId ?? undefined,
  });
  if (error) {
    const code = rpcErrorCode(error);
    const message = rpcMessage(error);
    if (code === '28000') return jsonError(c, 401, 'unauthorized', { message });
    if (code === '42501' || /forbidden|cannot view/i.test(message)) {
      return jsonError(c, 403, 'crew_share_change_forbidden', { message });
    }
    if (code === '22023') return jsonError(c, 400, 'crew_share_invalid', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({
    shareChangeId: changeId as string,
    requiresSubjectApprovals: requiredApprovalsArr,
  });
});

// ─────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function isUuid(s: string): boolean {
  return UUID_RE.test(s);
}

type AccessibleSubjectIds = { ids: string[]; error: null } | { ids: never[]; error: Response };

/**
 * Subjects the caller can act on or see crews for. Two sources:
 *
 *   1. The caller's own user_account subject (always exactly one row).
 *   2. group_account subjects via group_subject_members where the caller
 *      has any of the listed roles.
 *
 * Pass `['owner', 'admin', 'member']` for visibility (the GET list
 * endpoint), and `['owner', 'admin']` for "may act for" gating.
 */
export async function accessibleSubjectIds(
  c: Parameters<typeof jsonError>[0],
  userId: string,
  roles: readonly string[],
): Promise<AccessibleSubjectIds> {
  const supa = serviceClient(c.env);
  const out = new Set<string>();
  // user_account subject
  {
    const { data, error } = await supa
      .from('subjects')
      .select('id')
      .eq('kind', 'user_account')
      .eq('user_id', userId)
      .eq('status', 'active')
      .maybeSingle();
    if (error) {
      return { ids: [], error: jsonError(c, 500, 'database_error', { detail: error.message }) };
    }
    if (data?.id) out.add(data.id);
  }
  // group_account subjects via membership
  {
    const { data, error } = await supa
      .from('group_subject_members')
      .select('subject_id')
      .eq('user_id', userId)
      .in('role', roles as string[]);
    if (error) {
      return { ids: [], error: jsonError(c, 500, 'database_error', { detail: error.message }) };
    }
    for (const row of data ?? []) {
      if (typeof row.subject_id === 'string') out.add(row.subject_id);
    }
  }
  return { ids: Array.from(out), error: null };
}
