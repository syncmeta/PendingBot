import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient, userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

export const runnerHostRoutes = new Hono<AppBindings>();

const RunnerKind = z.enum([
  'cloud_sandbox',
  'local_claude_code',
  'local_codex',
  'local_opencode',
  'local_kilo',
]);

const JsonObject = z.record(z.string(), z.unknown());

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

function mapRpcError(c: Parameters<typeof jsonError>[0], err: unknown) {
  const message = rpcMessage(err);
  if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
  if (/forbidden/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
  if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
  return jsonError(c, 500, 'database_error', { detail: message });
}

function runnerDeviceGrant(c: Parameters<typeof jsonError>[0]) {
  if (c.var.authKind !== 'device_grant' || !c.var.deviceGrant) {
    return null;
  }
  return c.var.deviceGrant;
}

function runnerDeviceGrantRequired(c: Parameters<typeof jsonError>[0]) {
  return jsonError(c, 403, 'forbidden', {
    message: 'runner host mutations require a subject device grant',
  });
}

const RegisterBody = z.object({
  responsibleSubjectId: z.string().uuid(),
  displayName: z.string().trim().max(80).optional(),
  capabilities: JsonObject.default({}),
  allowedRunnerKinds: z.array(RunnerKind).default([]),
});

runnerHostRoutes.post('/', requireSubjectAuth(['runner:write']), async (c) => {
  let parsed: z.infer<typeof RegisterBody>;
  try {
    parsed = RegisterBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const deviceGrant = runnerDeviceGrant(c);
  if (!deviceGrant) return runnerDeviceGrantRequired(c);
  if (parsed.responsibleSubjectId !== deviceGrant.subjectId) {
    return jsonError(c, 403, 'forbidden');
  }
  const now = new Date().toISOString();
  const runnerHostId = crypto.randomUUID();
  const { error } = await serviceClient(c.env).from('runner_hosts').insert({
    id: runnerHostId,
    responsible_subject_id: parsed.responsibleSubjectId,
    platform: 'macos',
    display_name: parsed.displayName ?? '',
    capabilities: parsed.capabilities as Json,
    allowed_runner_kinds: parsed.allowedRunnerKinds as Json,
    status: 'online',
    last_seen_at: now,
    created_at: now,
    updated_at: now,
  });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ runnerHostId });
});

runnerHostRoutes.get('/', requireSubjectAuth(['runner:read']), async (c) => {
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  let query = supa
    .from('runner_hosts')
    .select('id, responsible_subject_id, platform, display_name, capabilities, allowed_runner_kinds, status, last_seen_at, created_at, updated_at')
    .order('updated_at', { ascending: false });
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    query = query.eq('responsible_subject_id', deviceGrant.subjectId);
  }
  const { data, error } = await query.limit(100);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ items: data ?? [] });
});

const HeartbeatBody = z.object({
  capabilities: JsonObject.optional(),
  allowedRunnerKinds: z.array(RunnerKind).optional(),
});

const ClaimNextBody = z.object({
  runnerKinds: z.array(RunnerKind).optional(),
});

const RunnerEventBody = z.object({
  eventType: z.enum([
    'started',
    'context_injected',
    'status',
    'tool_call',
    'tool_result',
    'permission_requested',
    'permission_resolved',
    'artifact_created',
    'posted_to_crew',
    'blocked',
  ]),
  visibility: z.enum(['controllers', 'crew_members', 'private_system']).default('crew_members'),
  summary: z.string().trim().max(1_000).optional(),
  payload: JsonObject.default({}),
  progressSummary: z.string().trim().max(1_000).optional(),
});

const RunnerAnnouncementBody = z.object({
  recipientSessionIds: z.array(z.string().uuid()).default([]),
  recipientMemberIds: z.array(z.string().uuid()).default([]),
  messageKind: z.enum(['announcement', 'instruction', 'status', 'question', 'handoff', 'result', 'blocker']).default('announcement'),
  summary: z.string().trim().min(1).max(2_000),
  payload: JsonObject.default({}),
  boardVisible: z.boolean().default(true),
});

const FinishBody = z.object({
  status: z.enum(['completed', 'failed', 'cancelled']),
  summary: z.string().trim().max(1_000).optional(),
  payload: JsonObject.default({}),
  progressSummary: z.string().trim().max(1_000).optional(),
});

runnerHostRoutes.post('/:id/heartbeat', requireSubjectAuth(['runner:write']), async (c) => {
  const runnerHostId = c.req.param('id');
  let parsed: z.infer<typeof HeartbeatBody>;
  try {
    parsed = HeartbeatBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const deviceGrant = runnerDeviceGrant(c);
  if (!deviceGrant) return runnerDeviceGrantRequired(c);
  const { data, error } = await serviceClient(c.env).rpc('runner_host_heartbeat_for_subject', {
    p_runner_host_id: runnerHostId,
    p_responsible_subject_id: deviceGrant.subjectId,
    p_capabilities: (parsed.capabilities ?? null) as Json,
    p_allowed_runner_kinds: (parsed.allowedRunnerKinds ?? null) as Json,
  } as never);
  if (error) return mapRpcError(c, error);
  return c.json({ ok: data === true });
});

runnerHostRoutes.post('/:id/claim-next', requireSubjectAuth(['runner:write']), async (c) => {
  const runnerHostId = c.req.param('id');
  let parsed: z.infer<typeof ClaimNextBody>;
  try {
    parsed = ClaimNextBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const deviceGrant = runnerDeviceGrant(c);
  if (!deviceGrant) return runnerDeviceGrantRequired(c);
  const { data, error } = await serviceClient(c.env).rpc('claim_next_crew_session_for_subject', {
    p_runner_host_id: runnerHostId,
    p_responsible_subject_id: deviceGrant.subjectId,
    p_runner_kinds: (parsed.runnerKinds ?? null) as Json,
  } as never);
  if (error) return mapRpcError(c, error);
  if (!data || typeof data !== 'object') {
    return c.json({ leaseId: null, session: null });
  }

  const claim = data as { lease_id?: unknown; session?: unknown };
  return c.json({
    leaseId: typeof claim.lease_id === 'string' ? claim.lease_id : null,
    session: claim.session ?? null,
  });
});

runnerHostRoutes.post('/:id/sessions/:sessionId/claim', requireSubjectAuth(['runner:write']), async (c) => {
  const runnerHostId = c.req.param('id');
  const sessionId = c.req.param('sessionId');
  let parsed: z.infer<typeof ClaimNextBody>;
  try {
    parsed = ClaimNextBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const deviceGrant = runnerDeviceGrant(c);
  if (!deviceGrant) return runnerDeviceGrantRequired(c);
  const { data, error } = await serviceClient(c.env).rpc('claim_crew_session_for_subject', {
    p_runner_host_id: runnerHostId,
    p_responsible_subject_id: deviceGrant.subjectId,
    p_crew_session_id: sessionId,
    p_runner_kinds: (parsed.runnerKinds ?? null) as Json,
  } as never);
  if (error) return mapRpcError(c, error);
  if (!data || typeof data !== 'object') {
    return c.json({ leaseId: null, session: null });
  }

  const claim = data as { lease_id?: unknown; session?: unknown };
  return c.json({
    leaseId: typeof claim.lease_id === 'string' ? claim.lease_id : null,
    session: claim.session ?? null,
  });
});

runnerHostRoutes.post('/:id/sessions/:sessionId/events', requireSubjectAuth(['runner:write']), async (c) => {
  const runnerHostId = c.req.param('id');
  const sessionId = c.req.param('sessionId');
  let parsed: z.infer<typeof RunnerEventBody>;
  try {
    parsed = RunnerEventBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const deviceGrant = runnerDeviceGrant(c);
  if (!deviceGrant) return runnerDeviceGrantRequired(c);
  const { data, error } = await serviceClient(c.env).rpc('append_crew_session_event_from_runner_for_subject', {
    p_runner_host_id: runnerHostId,
    p_responsible_subject_id: deviceGrant.subjectId,
    p_crew_session_id: sessionId,
    p_event_type: parsed.eventType,
    p_visibility: parsed.visibility,
    p_summary: parsed.summary ?? '',
    p_payload: parsed.payload as Json,
    p_progress_summary: parsed.progressSummary,
  } as never);
  if (error) return mapRpcError(c, error);
  return c.json({ eventId: data });
});

runnerHostRoutes.post('/:id/sessions/:sessionId/announcements', requireSubjectAuth(['runner:write']), async (c) => {
  const runnerHostId = c.req.param('id');
  const sessionId = c.req.param('sessionId');
  let parsed: z.infer<typeof RunnerAnnouncementBody>;
  try {
    parsed = RunnerAnnouncementBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    const { data, error } = await serviceClient(c.env).rpc('create_crew_announcement_from_runner_for_subject', {
      p_runner_host_id: runnerHostId,
      p_responsible_subject_id: deviceGrant.subjectId,
      p_crew_session_id: sessionId,
      p_recipient_session_ids: parsed.recipientSessionIds as Json,
      p_recipient_member_ids: parsed.recipientMemberIds as Json,
      p_message_kind: parsed.messageKind,
      p_summary: parsed.summary,
      p_payload: parsed.payload as Json,
      p_board_visible: parsed.boardVisible,
    } as never);
    if (error) return mapRpcError(c, error);
    return c.json({ announcementId: data });
  }

  return jsonError(c, 403, 'forbidden', {
    message: 'runner announcements require a subject device grant',
  });
});

runnerHostRoutes.post('/:id/sessions/:sessionId/finish', requireSubjectAuth(['runner:write']), async (c) => {
  const runnerHostId = c.req.param('id');
  const sessionId = c.req.param('sessionId');
  let parsed: z.infer<typeof FinishBody>;
  try {
    parsed = FinishBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const deviceGrant = runnerDeviceGrant(c);
  if (!deviceGrant) return runnerDeviceGrantRequired(c);
  const { data, error } = await serviceClient(c.env).rpc('finish_crew_session_from_runner_for_subject', {
    p_runner_host_id: runnerHostId,
    p_responsible_subject_id: deviceGrant.subjectId,
    p_crew_session_id: sessionId,
    p_status: parsed.status,
    p_summary: parsed.summary ?? '',
    p_payload: parsed.payload as Json,
    p_progress_summary: parsed.progressSummary,
  } as never);
  if (error) return mapRpcError(c, error);
  return c.json({ ok: data === true });
});
