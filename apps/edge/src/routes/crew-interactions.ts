// T4.5 交互（Human-in-the-loop Interaction）HTTP 层 — spec v2 §10（重写版）。
//
// session 跑的 agent 经 `ask_human` MCP 工具发起交互，阻塞等人答。三个端点：
//
//   POST /v1/sessions/:sessionId/interactions      (runner device-grant)
//       body { question, payload? } → create_interaction_request → { requestId }
//       发起一次交互（落 permission_requests request_kind='question' + 交互卡）。
//
//   GET  /v1/sessions/:sessionId/interactions/:reqId  (runner device-grant)
//       runner 的 MCP 工具 long-poll：→ { status, replyText }
//       status='answered' 时 replyText 是人类回复，工具把它返回给 agent 解阻塞。
//
//   POST /v1/interactions/:reqId/answer            (user / device-grant)
//       body { reply } → answer_interaction_request → { ok }
//       人类（或 captain，溯源到的责任主体）回自由文本。ACL 在 RPC 内（同
//       decide_permission_request：user_account 本人 / group_account owner|admin）。
//
// 鉴权沿用 session-proxy 的 device-grant 形状：runner 端要 runner:write +
// grant subject === session.responsible_subject。captain 自决 / 沿 DAG 层层
// 溯源（spec §10.3-10.5）暂不在这做，v1 直接发卡给责任主体（direct_to_human）。

import { Hono, type Context } from 'hono';
import { z } from 'zod';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient, type SupabaseClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (s: string): boolean => UUID_RE.test(s);

/** /v1/sessions/:sessionId/interactions（runner 发起 + long-poll） */
export const crewInteractionRoutes = new Hono<AppBindings>();
/** /v1/interactions/:reqId/answer（人类回复） */
export const crewInteractionAnswerRoutes = new Hono<AppBindings>();

// ── runner 发起交互 ────────────────────────────────────────────────────
crewInteractionRoutes.post('/:sessionId/interactions', requireSubjectAuth(['runner:write']), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });

  const parsed = z.object({
    question: z.string().trim().min(1).max(8000),
    payload: z.record(z.string(), z.unknown()).optional(),
  }).safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });

  const svc = serviceClient(c.env);
  const session = await loadOwnedSession(c, svc, sessionId);
  if ('errorResponse' in session) return session.errorResponse;

  const { data, error } = await svc.rpc('create_interaction_request', {
    p_session_id: sessionId,
    p_question: parsed.data.question,
    p_payload: (parsed.data.payload ?? {}) as Json,
  });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ requestId: typeof data === 'string' ? data : null });
});

// ── 列出某 session 的待答交互（操作者 UI 拉去答） ───────────────────────
crewInteractionRoutes.get('/:sessionId/interactions', requireSubjectAuth([]), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });

  const svc = serviceClient(c.env);
  const session = await loadOwnedSession(c, svc, sessionId);
  if ('errorResponse' in session) return session.errorResponse;

  const { data, error } = await svc
    .from('permission_requests')
    .select('id, requested_action, detail, status, requested_at, request_kind')
    .eq('crew_session_id', sessionId)
    .eq('request_kind', 'question')
    .eq('status', 'pending')
    .order('requested_at', { ascending: true });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  const rows = data ?? [];
  return c.json({ items: rows.map((r) => ({ id: r.id, question: r.requested_action, detail: r.detail, requestedAt: r.requested_at })) });
});

// ── runner long-poll 读回复 ────────────────────────────────────────────
crewInteractionRoutes.get('/:sessionId/interactions/:reqId', requireSubjectAuth(['runner:write']), async (c) => {
  const sessionId = c.req.param('sessionId');
  const reqId = c.req.param('reqId');
  if (!isUuid(sessionId) || !isUuid(reqId)) return jsonError(c, 400, 'invalid_id', { message: 'ids must be uuids' });

  const svc = serviceClient(c.env);
  const session = await loadOwnedSession(c, svc, sessionId);
  if ('errorResponse' in session) return session.errorResponse;

  const { data, error } = await svc
    .from('permission_requests')
    .select('id, status, reply_text, crew_session_id')
    .eq('id', reqId)
    .maybeSingle();
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  const row = data as { status?: string; reply_text?: string | null; crew_session_id?: string } | null;
  if (!row || row.crew_session_id !== sessionId) return jsonError(c, 404, 'not_found', { message: 'interaction not found' });
  return c.json({ status: row.status ?? 'pending', replyText: row.reply_text ?? null });
});

// ── 人类回复 ───────────────────────────────────────────────────────────
crewInteractionAnswerRoutes.post('/:reqId/answer', requireSubjectAuth([]), async (c) => {
  const reqId = c.req.param('reqId');
  if (!isUuid(reqId)) return jsonError(c, 400, 'invalid_id', { message: 'reqId must be a uuid' });

  const parsed = z.object({ reply: z.string().max(8000) }).safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });

  // Resolve the answering human: a device grant carries grantedByUserId; a
  // Supabase-JWT user is c.var.userId. The RPC re-checks the ACL against this.
  const callerUserId = c.var.authKind === 'device_grant'
    ? c.var.deviceGrant?.grantedByUserId ?? null
    : c.var.userId ?? null;
  if (!callerUserId) return jsonError(c, 401, 'unauthorized');

  const svc = serviceClient(c.env);
  const { error } = await svc.rpc('answer_interaction_request', {
    p_id: reqId,
    p_reply_text: parsed.data.reply,
    p_caller_user_id: callerUserId,
  });
  if (error) {
    // RPC raises 42501 on ACL fail, 22023 on bad state, P0002 on missing.
    const msg = error.message.toLowerCase();
    if (msg.includes('forbidden')) return jsonError(c, 403, 'forbidden', { message: error.message });
    if (msg.includes('not found')) return jsonError(c, 404, 'not_found', { message: error.message });
    if (msg.includes('already answered') || msg.includes('not an interaction')) {
      return jsonError(c, 409, 'conflict', { message: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ ok: true });
});

// ── helper：解析 session 行 + gate device-grant runner 的 subject 一致 ────
type OwnedSession = { id: string; responsible_subject_id: string; crew_conversation_id: string };
async function loadOwnedSession(
  c: Context<AppBindings>,
  svc: SupabaseClient,
  sessionId: string,
): Promise<OwnedSession | { errorResponse: Response }> {
  const { data, error } = await svc
    .from('crew_sessions')
    .select('id, responsible_subject_id, crew_conversation_id')
    .eq('id', sessionId)
    .maybeSingle();
  if (error) return { errorResponse: jsonError(c, 500, 'database_error', { detail: error.message }) };
  const row = data as OwnedSession | null;
  if (!row) return { errorResponse: jsonError(c, 404, 'session_not_found') };
  // device-grant runner must belong to the session's responsible subject.
  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg || dg.subjectId !== row.responsible_subject_id) {
      return { errorResponse: jsonError(c, 403, 'session_forbidden') };
    }
  }
  return row;
}
