// Machine registry endpoints (PendingCrew Mac / iPad device registry).
//
// Mounted at `/v1/machines`. Lets a client register the device it's
// running on and list every machine the caller's account knows about.
// Backed by the `pendingbot.machine` table (RLS-scoped to the caller's
// own `user_account` subject) and the service-role
// `upsert_self_machine(p_subject_id, p_device_id, p_display_name)` RPC,
// which upserts on conflict (subject_id, device_id).
//
//   GET  /v1/machines              — list the account's machines
//   POST /v1/machines/register-self — register/refresh the current device
//
// Auth mirrors `crews.ts`: accepts BOTH a supabase user JWT and a
// PendingCrew device grant (`pdg_*`). JWT callers act as their own uid;
// device-grant callers act on behalf of the approving user
// (`grantedByUserId`). Either way we resolve that user's personal
// `user_account` subject and scope all machine rows to it.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const machinesRoutes = new Hono<AppBindings>();
// `crew:read` is the floor every PendingCrew grant carries — same gate
// the crews read surface uses.
machinesRoutes.use('*', requireSubjectAuth(['crew:read']));

// Resolve the acting supabase user id regardless of auth kind. JWT
// callers → their own uid; device-grant callers → the approving user
// (`grantedByUserId`). Returns a 403 Response if a device grant is
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

// The caller's personal `user_account` subject id, or null if they have
// none (should be exactly one row for any active account). Machine rows
// are always scoped to this subject.
async function ownSubjectId(
  c: Parameters<typeof jsonError>[0],
  userId: string,
): Promise<{ subjectId: string | null; error: null } | { subjectId: null; error: Response }> {
  const supa = serviceClient(c.env);
  const { data, error } = await supa
    .from('subjects')
    .select('id')
    .eq('kind', 'user_account')
    .eq('user_id', userId)
    .eq('status', 'active')
    .maybeSingle();
  if (error) {
    return { subjectId: null, error: jsonError(c, 500, 'database_error', { detail: error.message }) };
  }
  return { subjectId: data?.id ?? null, error: null };
}

// ─────────────────────────────────────────────────────────────
// GET /v1/machines — list the account's machines
// ─────────────────────────────────────────────────────────────

machinesRoutes.get('/', async (c) => {
  const actor = actingUserId(c);
  if ('error' in actor) return actor.error;

  const subject = await ownSubjectId(c, actor.userId);
  if (subject.error) return subject.error;
  if (!subject.subjectId) return c.json({ machines: [] });

  const supa = serviceClient(c.env);
  const { data: rows, error } = await supa
    .from('machine')
    .select('id, kind, device_id, display_name, fly_machine_id, status, last_seen_at, created_at')
    .eq('subject_id', subject.subjectId)
    .order('created_at', { ascending: true })
    .limit(200);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const machines = (rows ?? []).map((row) => ({
    id: row.id,
    kind: row.kind,
    deviceId: row.device_id,
    displayName: row.display_name,
    flyMachineId: row.fly_machine_id,
    status: row.status,
    lastSeenAt: row.last_seen_at,
  }));
  return c.json({ machines });
});

// ─────────────────────────────────────────────────────────────
// POST /v1/machines/register-self — register/refresh the current device
// ─────────────────────────────────────────────────────────────

const RegisterSelfBody = z.object({
  deviceId: z.string().trim().min(1).max(200),
  displayName: z.string().trim().min(1).max(120),
});

machinesRoutes.post('/register-self', async (c) => {
  let parsed: z.infer<typeof RegisterSelfBody>;
  try {
    parsed = RegisterSelfBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const actor = actingUserId(c);
  if ('error' in actor) return actor.error;

  const subject = await ownSubjectId(c, actor.userId);
  if (subject.error) return subject.error;
  if (!subject.subjectId) return jsonError(c, 404, 'subject_not_found');

  const supa = serviceClient(c.env);
  const { data: machineId, error } = await supa.rpc('upsert_self_machine', {
    p_subject_id: subject.subjectId,
    p_device_id: parsed.deviceId,
    p_display_name: parsed.displayName,
  });
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ machineId: machineId as string });
});
