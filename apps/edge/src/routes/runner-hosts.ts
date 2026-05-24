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
