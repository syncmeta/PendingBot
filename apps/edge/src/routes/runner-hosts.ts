import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

export const runnerHostRoutes = new Hono<AppBindings>();
runnerHostRoutes.use('*', requireSession());

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

const RegisterBody = z.object({
  responsibleSubjectId: z.string().uuid(),
  displayName: z.string().trim().max(80).optional(),
  capabilities: JsonObject.default({}),
  allowedRunnerKinds: z.array(RunnerKind).default([]),
});

runnerHostRoutes.post('/', async (c) => {
  const userJwt = c.var.userJwt!;
  let parsed: z.infer<typeof RegisterBody>;
  try {
    parsed = RegisterBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('register_runner_host', {
    p_responsible_subject_id: parsed.responsibleSubjectId,
    p_display_name: parsed.displayName ?? '',
    p_capabilities: parsed.capabilities as Json,
    p_allowed_runner_kinds: parsed.allowedRunnerKinds as Json,
  });
  if (error) return mapRpcError(c, error);
  return c.json({ runnerHostId: data });
});

runnerHostRoutes.get('/', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('runner_hosts')
    .select('id, responsible_subject_id, platform, display_name, capabilities, allowed_runner_kinds, status, last_seen_at, created_at, updated_at')
    .order('updated_at', { ascending: false })
    .limit(100);
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

const FinishBody = z.object({
  status: z.enum(['completed', 'failed', 'cancelled']),
  summary: z.string().trim().max(1_000).optional(),
  payload: JsonObject.default({}),
  progressSummary: z.string().trim().max(1_000).optional(),
});

runnerHostRoutes.post('/:id/heartbeat', async (c) => {
  const userJwt = c.var.userJwt!;
  const runnerHostId = c.req.param('id');
  let parsed: z.infer<typeof HeartbeatBody>;
  try {
    parsed = HeartbeatBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('runner_host_heartbeat', {
    p_runner_host_id: runnerHostId,
    p_capabilities: (parsed.capabilities ?? null) as Json,
    p_allowed_runner_kinds: (parsed.allowedRunnerKinds ?? null) as Json,
  });
  if (error) return mapRpcError(c, error);
  return c.json({ ok: data === true });
});

runnerHostRoutes.post('/:id/claim-next', async (c) => {
  const userJwt = c.var.userJwt!;
  const runnerHostId = c.req.param('id');
  let parsed: z.infer<typeof ClaimNextBody>;
  try {
    parsed = ClaimNextBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('claim_next_crew_session', {
    p_runner_host_id: runnerHostId,
    p_runner_kinds: (parsed.runnerKinds ?? null) as Json,
  });
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

runnerHostRoutes.post('/:id/sessions/:sessionId/events', async (c) => {
  const userJwt = c.var.userJwt!;
  const runnerHostId = c.req.param('id');
  const sessionId = c.req.param('sessionId');
  let parsed: z.infer<typeof RunnerEventBody>;
  try {
    parsed = RunnerEventBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('append_crew_session_event_from_runner', {
    p_runner_host_id: runnerHostId,
    p_crew_session_id: sessionId,
    p_event_type: parsed.eventType,
    p_visibility: parsed.visibility,
    p_summary: parsed.summary ?? '',
    p_payload: parsed.payload as Json,
    p_progress_summary: parsed.progressSummary ?? null,
  });
  if (error) return mapRpcError(c, error);
  return c.json({ eventId: data });
});

runnerHostRoutes.post('/:id/sessions/:sessionId/finish', async (c) => {
  const userJwt = c.var.userJwt!;
  const runnerHostId = c.req.param('id');
  const sessionId = c.req.param('sessionId');
  let parsed: z.infer<typeof FinishBody>;
  try {
    parsed = FinishBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('finish_crew_session_from_runner', {
    p_runner_host_id: runnerHostId,
    p_crew_session_id: sessionId,
    p_status: parsed.status,
    p_summary: parsed.summary ?? '',
    p_payload: parsed.payload as Json,
    p_progress_summary: parsed.progressSummary ?? null,
  });
  if (error) return mapRpcError(c, error);
  return c.json({ ok: data === true });
});
