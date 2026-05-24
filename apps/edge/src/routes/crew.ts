import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const crewRoutes = new Hono<AppBindings>();
crewRoutes.use('*', requireSession());

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

const CreateCrewBody = z.object({
  responsibleSubjectId: z.string().uuid(),
  title: z.string().trim().max(80).optional(),
});

const RunnerKind = z.enum([
  'cloud_sandbox',
  'local_claude_code',
  'local_codex',
  'local_opencode',
  'local_kilo',
]);

crewRoutes.post('/', async (c) => {
  const userJwt = c.var.userJwt!;
  let parsed: z.infer<typeof CreateCrewBody>;
  try {
    parsed = CreateCrewBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('open_crew_conv', {
    p_responsible_subject_id: parsed.responsibleSubjectId,
    p_title: parsed.title ?? '',
  });
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) {
      return jsonError(c, 401, 'unauthorized', { message });
    }
    if (/forbidden/i.test(message)) {
      return jsonError(c, 403, 'forbidden', { message });
    }
    if (/not found/i.test(message)) {
      return jsonError(c, 404, 'not_found', { message });
    }
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({ conversationId: data });
});

const CreateSessionBody = z.object({
  runnerKind: RunnerKind,
  taskBrief: z.string().trim().min(1).max(12_000),
});

crewRoutes.post('/:id/sessions', async (c) => {
  const crewConversationId = c.req.param('id');
  const userJwt = c.var.userJwt!;
  let parsed: z.infer<typeof CreateSessionBody>;
  try {
    parsed = CreateSessionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('open_crew_session', {
    p_crew_conversation_id: crewConversationId,
    p_runner_kind: parsed.runnerKind,
    p_task_brief: parsed.taskBrief,
  });
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    if (/forbidden|not an active crew member/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
    if (/invalid|required/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({ sessionId: data });
});

crewRoutes.get('/:id/sessions', async (c) => {
  const crewConversationId = c.req.param('id');
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('crew_sessions')
    .select('id, crew_conversation_id, responsible_subject_id, runner_kind, status, task_brief, progress_summary, created_at, started_at, finished_at')
    .eq('crew_conversation_id', crewConversationId)
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ items: data ?? [] });
});

crewRoutes.get('/sessions/:sessionId/events', async (c) => {
  const sessionId = c.req.param('sessionId');
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('session_events')
    .select('id, crew_session_id, event_type, visibility, summary, payload, created_at')
    .eq('crew_session_id', sessionId)
    .order('created_at', { ascending: true })
    .limit(200);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ items: data ?? [] });
});

crewRoutes.get('/', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const limitParam = Number.parseInt(c.req.query('limit') ?? '', 10);
  const limit = Math.min(Math.max(Number.isFinite(limitParam) ? limitParam : 50, 1), 100);

  const { data: metaRows, error } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, status, title, created_at, updated_at')
    .eq('temporary_kind', 'crew')
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }

  const metas = metaRows ?? [];
  const convIds = metas.map((m) => m.conversation_id);
  const svc = serviceClient(c.env);
  const { data: convRows, error: convErr } = convIds.length
    ? await svc
      .from('conversations')
      .select('id, title, created_at, updated_at')
      .in('id', convIds)
    : { data: [], error: null };
  if (convErr) {
    return jsonError(c, 500, 'database_error', { detail: convErr.message });
  }

  const convById = new Map((convRows ?? []).map((row) => [row.id, row]));
  return c.json({
    items: metas.map((meta) => {
      const conv = convById.get(meta.conversation_id);
      return {
        conversation_id: meta.conversation_id,
        responsible_subject_id: meta.responsible_subject_id,
        status: meta.status,
        title: meta.title ?? conv?.title ?? 'Crew',
        created_at: meta.created_at,
        updated_at: meta.updated_at ?? conv?.updated_at ?? meta.created_at,
      };
    }),
  });
});
