import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient, userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

export const crewRoutes = new Hono<AppBindings>();

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

const CreateChildCrewBody = z.object({
  title: z.string().trim().min(1).max(80),
});

const RunnerKind = z.enum([
  'cloud_sandbox',
  'local_claude_code',
  'local_codex',
  'local_opencode',
  'local_kilo',
]);

const JsonObject = z.record(z.string(), z.unknown());

const AnnouncementBody = z.object({
  recipientSessionIds: z.array(z.string().uuid()).default([]),
  recipientMemberIds: z.array(z.string().uuid()).default([]),
  messageKind: z.enum(['announcement', 'instruction', 'status', 'question', 'handoff', 'result', 'blocker']).default('announcement'),
  summary: z.string().trim().min(1).max(2_000),
  payload: JsonObject.default({}),
  boardVisible: z.boolean().default(true),
});

crewRoutes.post('/', requireSubjectAuth(['crew:write']), async (c) => {
  let parsed: z.infer<typeof CreateCrewBody>;
  try {
    parsed = CreateCrewBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (c.var.authKind === 'device_grant') {
    if (parsed.responsibleSubjectId !== c.var.deviceGrant?.subjectId) {
      return jsonError(c, 403, 'forbidden');
    }
    if (!c.var.deviceGrant.grantedByUserId) {
      return jsonError(c, 403, 'forbidden');
    }
    const { data, error } = await serviceClient(c.env).rpc('open_crew_conv_for_subject', {
      p_responsible_subject_id: parsed.responsibleSubjectId,
      p_actor_user_id: c.var.deviceGrant.grantedByUserId,
      p_title: parsed.title ?? '',
    } as never);
    if (error) {
      const message = rpcMessage(error);
      if (/forbidden/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
      if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    return c.json({ conversationId: data });
  }

  const userJwt = c.var.userJwt!;
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

crewRoutes.post('/:id/sessions', requireSubjectAuth(['crew:write']), async (c) => {
  const crewConversationId = c.req.param('id');
  let parsed: z.infer<typeof CreateSessionBody>;
  try {
    parsed = CreateSessionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (c.var.authKind === 'device_grant') {
    if (!c.var.deviceGrant?.grantedByUserId) {
      return jsonError(c, 403, 'forbidden');
    }
    const { data, error } = await serviceClient(c.env).rpc('open_crew_session_for_subject', {
      p_crew_conversation_id: crewConversationId,
      p_responsible_subject_id: c.var.deviceGrant.subjectId,
      p_actor_user_id: c.var.deviceGrant.grantedByUserId,
      p_runner_kind: parsed.runnerKind,
      p_task_brief: parsed.taskBrief,
    } as never);
    if (error) {
      const message = rpcMessage(error);
      if (/forbidden|not an active crew member/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
      if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
      if (/invalid|required/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    return c.json({ sessionId: data });
  }

  const userJwt = c.var.userJwt!;
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

crewRoutes.post('/:id/children', requireSubjectAuth(['crew:write']), async (c) => {
  const parentCrewConversationId = c.req.param('id');
  let parsed: z.infer<typeof CreateChildCrewBody>;
  try {
    parsed = CreateChildCrewBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant?.grantedByUserId) {
      return jsonError(c, 403, 'forbidden');
    }
    const { data, error } = await serviceClient(c.env).rpc('create_child_crew_inheriting_responsibility_for_subject' as never, {
      p_parent_crew_conversation_id: parentCrewConversationId,
      p_granted_subject_id: deviceGrant.subjectId,
      p_actor_user_id: deviceGrant.grantedByUserId,
      p_title: parsed.title,
    } as never);
    if (error) {
      const message = rpcMessage(error);
      if (/forbidden/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
      if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
      if (/invalid|required/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    return c.json({ conversationId: data });
  }

  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('create_child_crew_inheriting_responsibility' as never, {
    p_parent_crew_conversation_id: parentCrewConversationId,
    p_title: parsed.title,
  } as never);
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    if (/forbidden/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
    if (/invalid|required/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({ conversationId: data });
});

async function deviceGrantCanReadCrew(c: Parameters<typeof jsonError>[0], crewConversationId: string): Promise<Response | null> {
  if (c.var.authKind !== 'device_grant') return null;
  const deviceGrant = c.var.deviceGrant;
  if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
  const svc = serviceClient(c.env);
  const { data, error } = await svc
    .from('temporary_group_meta')
    .select('conversation_id')
    .eq('conversation_id', crewConversationId)
    .eq('temporary_kind', 'crew')
    .eq('responsible_subject_id', deviceGrant.subjectId)
    .maybeSingle();
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  if (data) return null;
  const looseSvc = svc as { from: (table: string) => any };
  const shareResult = await looseSvc
    .from('crew_resolved_responsibility_shares')
    .select('crew_conversation_id')
    .eq('crew_conversation_id', crewConversationId)
    .eq('subject_id', deviceGrant.subjectId)
    .maybeSingle();
  if (shareResult.error) return jsonError(c, 500, 'database_error', { detail: shareResult.error.message });
  return shareResult.data ? null : jsonError(c, 404, 'not_found');
}

async function subjectAuthCanReadCrew(c: Parameters<typeof jsonError>[0], crewConversationId: string): Promise<Response | null> {
  if (c.var.authKind === 'device_grant') {
    return deviceGrantCanReadCrew(c, crewConversationId);
  }
  const userId = c.var.userId;
  const userJwt = c.var.userJwt;
  if (!userId || !userJwt) return jsonError(c, 401, 'unauthorized');
  const { data, error } = await userClient(c.env, userJwt).rpc('can_view_temporary_group' as never, {
    p_conversation_id: crewConversationId,
    p_user_id: userId,
  } as never);
  if (error) return jsonError(c, 500, 'database_error', { detail: rpcMessage(error) });
  return data === true ? null : jsonError(c, 404, 'not_found');
}

type CrewLinkSummaryRow = {
  current_crew_id: string;
  linked_crew_id: string;
  direction: 'parent' | 'child';
  title: string | null;
  status: string;
  runtime_location: string;
  captain_bot_id: string | null;
  captain_member_id: string | null;
  created_at: string;
};

type CrewResponsibilityShareRow = {
  crew_conversation_id: string;
  subject_id: string;
  share_bps: number;
  source: string;
};

function serializeCrewLink(row: CrewLinkSummaryRow) {
  return {
    crew_conversation_id: row.linked_crew_id,
    title: row.title ?? 'Crew',
    status: row.status,
    runtime_location: row.runtime_location,
    captain_bot_id: row.captain_bot_id,
    captain_member_id: row.captain_member_id,
    created_at: row.created_at,
  };
}

crewRoutes.get('/:id/links', requireSubjectAuth(['crew:read']), async (c) => {
  const crewConversationId = c.req.param('id');
  const denied = await subjectAuthCanReadCrew(c, crewConversationId);
  if (denied) return denied;
  const looseSupa = serviceClient(c.env) as { from: (table: string) => any };

  const [linksResult, sharesResult] = await Promise.all([
    looseSupa
      .from('crew_link_summaries')
      .select('current_crew_id, linked_crew_id, direction, title, status, runtime_location, captain_bot_id, captain_member_id, created_at')
      .eq('current_crew_id', crewConversationId)
      .order('created_at', { ascending: true }),
    looseSupa
      .from('crew_resolved_responsibility_shares')
      .select('crew_conversation_id, subject_id, share_bps, source')
      .eq('crew_conversation_id', crewConversationId)
      .order('subject_id', { ascending: true }),
  ]);

  if (linksResult.error) return jsonError(c, 500, 'database_error', { detail: linksResult.error.message });
  if (sharesResult.error) return jsonError(c, 500, 'database_error', { detail: sharesResult.error.message });

  const links = (linksResult.data ?? []) as CrewLinkSummaryRow[];
  const shares = (sharesResult.data ?? []) as CrewResponsibilityShareRow[];
  return c.json({
    parents: links.filter((row) => row.direction === 'parent').map(serializeCrewLink),
    children: links.filter((row) => row.direction === 'child').map(serializeCrewLink),
    responsibilityShares: shares.map((row) => ({
      subject_id: row.subject_id,
      share_bps: row.share_bps,
      source: row.source,
    })),
  });
});

crewRoutes.get('/:id/sessions', requireSubjectAuth(['crew:read']), async (c) => {
  const crewConversationId = c.req.param('id');
  const denied = await deviceGrantCanReadCrew(c, crewConversationId);
  if (denied) return denied;
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
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

crewRoutes.post('/:id/announcements', requireSubjectAuth(['crew:write']), async (c) => {
  const crewConversationId = c.req.param('id');
  let parsed: z.infer<typeof AnnouncementBody>;
  try {
    parsed = AnnouncementBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant?.grantedByUserId) return jsonError(c, 403, 'forbidden');
    const { data, error } = await serviceClient(c.env).rpc('create_crew_announcement_for_subject', {
      p_crew_conversation_id: crewConversationId,
      p_responsible_subject_id: deviceGrant.subjectId,
      p_actor_user_id: deviceGrant.grantedByUserId,
      p_recipient_session_ids: parsed.recipientSessionIds as Json,
      p_recipient_member_ids: parsed.recipientMemberIds as Json,
      p_message_kind: parsed.messageKind,
      p_summary: parsed.summary,
      p_payload: parsed.payload as Json,
      p_board_visible: parsed.boardVisible,
    } as never);
    if (error) {
      const message = rpcMessage(error);
      if (/forbidden|not an active crew member/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
      if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
      if (/invalid|required|recipient/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    return c.json({ announcementId: data });
  }

  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('create_crew_announcement', {
    p_crew_conversation_id: crewConversationId,
    p_recipient_session_ids: parsed.recipientSessionIds as Json,
    p_recipient_member_ids: parsed.recipientMemberIds as Json,
    p_message_kind: parsed.messageKind,
    p_summary: parsed.summary,
    p_payload: parsed.payload as Json,
    p_board_visible: parsed.boardVisible,
  });
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    if (/forbidden|not an active crew member/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
    if (/invalid|required|recipient/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({ announcementId: data });
});

crewRoutes.get('/:id/announcements', requireSubjectAuth(['crew:read']), async (c) => {
  const crewConversationId = c.req.param('id');
  const denied = await deviceGrantCanReadCrew(c, crewConversationId);
  if (denied) return denied;
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa
    .from('crew_announcements')
    .select('id, crew_conversation_id, responsible_subject_id, sender_kind, sender_member_id, sender_session_id, recipient_mode, message_kind, board_visible, summary, payload, created_at')
    .eq('crew_conversation_id', crewConversationId)
    .eq('board_visible', true)
    .order('created_at', { ascending: true })
    .limit(200);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const announcements = data ?? [];
  const announcementIds = announcements.map((row) => row.id);
  type AnnouncementMentionRow = {
    id: string;
    announcement_id: string;
    target_kind: string;
    target_session_id: string | null;
    target_member_id: string | null;
    created_at: string;
  };
  const mentionResult = announcementIds.length
    ? await supa
      .from('crew_announcement_mentions')
      .select('id, announcement_id, target_kind, target_session_id, target_member_id, created_at')
      .in('announcement_id', announcementIds)
      .order('created_at', { ascending: true })
    : { data: [], error: null };
  const mentionRows = (mentionResult.data ?? []) as AnnouncementMentionRow[];
  const mentionErr = mentionResult.error;
  if (mentionErr) {
    return jsonError(c, 500, 'database_error', { detail: mentionErr.message });
  }
  const mentionsByAnnouncement = new Map<string, AnnouncementMentionRow[]>();
  for (const mention of mentionRows) {
    const list = mentionsByAnnouncement.get(mention.announcement_id) ?? [];
    list.push(mention);
    mentionsByAnnouncement.set(mention.announcement_id, list);
  }
  return c.json({
    items: announcements.map((announcement) => ({
      ...announcement,
      mentions: mentionsByAnnouncement.get(announcement.id) ?? [],
    })),
  });
});

crewRoutes.get('/:id/members', requireSubjectAuth(['crew:read']), async (c) => {
  const crewConversationId = c.req.param('id');
  const denied = await deviceGrantCanReadCrew(c, crewConversationId);
  if (denied) return denied;
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa
    .from('temporary_group_members')
    .select('id, conversation_id, member_kind, user_id, bot_id, code_session_id, display_name, role, capabilities, status, created_at')
    .eq('conversation_id', crewConversationId)
    .eq('status', 'active')
    .order('created_at', { ascending: true });
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ items: data ?? [] });
});

// GET /v1/crew/sessions — 跨 crew 聚合的 session 列表(机组 tab 列表页主数据)。
// user JWT 走 userClient,RLS(can_view_crew_session)圈出可见范围;
// device_grant 按 responsible_subject_id 过滤。按 updated_at 倒序。
crewRoutes.get('/sessions', requireSubjectAuth(['crew:read']), async (c) => {
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  let query = supa
    .from('crew_sessions')
    .select('id, crew_conversation_id, responsible_subject_id, runner_kind, status, task_brief, progress_summary, created_at, updated_at, started_at, finished_at')
    .order('updated_at', { ascending: false });
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    query = query.eq('responsible_subject_id', deviceGrant.subjectId);
  }
  const { data, error } = await query.limit(100);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ items: data ?? [] });
});

// GET /v1/crew/sessions/:sessionId/permission-requests — 单 session 的权限
// 请求列表(机组 tab 详情页权限卡)。user JWT 走 RLS;device_grant 校验
// session 归属后走 service client。倒序,limit 50。
crewRoutes.get('/sessions/:sessionId/permission-requests', requireSubjectAuth(['crew:read']), async (c) => {
  const sessionId = c.req.param('sessionId');
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    const { data: session, error: sessionErr } = await supa
      .from('crew_sessions')
      .select('id, responsible_subject_id')
      .eq('id', sessionId)
      .eq('responsible_subject_id', deviceGrant.subjectId)
      .maybeSingle();
    if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
    if (!session) return jsonError(c, 404, 'not_found');
  }
  const { data, error } = await supa
    .from('permission_requests')
    .select('id, crew_session_id, requested_action, request_kind, risk_level, detail, status, reply_text, requested_at, decided_by_user_id, decided_at')
    .eq('crew_session_id', sessionId)
    .order('requested_at', { ascending: false })
    .limit(50);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ items: data ?? [] });
});

crewRoutes.get('/sessions/:sessionId/events', requireSubjectAuth(['crew:read']), async (c) => {
  const sessionId = c.req.param('sessionId');
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    const { data: session, error: sessionErr } = await supa
      .from('crew_sessions')
      .select('id, responsible_subject_id')
      .eq('id', sessionId)
      .eq('responsible_subject_id', deviceGrant.subjectId)
      .maybeSingle();
    if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
    if (!session) return jsonError(c, 404, 'not_found');
  }
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

crewRoutes.get('/sessions/:sessionId/mailbox', requireSubjectAuth(['crew:read']), async (c) => {
  const sessionId = c.req.param('sessionId');
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    const { data: session, error: sessionErr } = await supa
      .from('crew_sessions')
      .select('id, responsible_subject_id')
      .eq('id', sessionId)
      .eq('responsible_subject_id', deviceGrant.subjectId)
      .maybeSingle();
    if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
    if (!session) return jsonError(c, 404, 'not_found');
  }
  const { data, error } = await supa
    .from('session_mailbox_items')
    .select('id, announcement_id, crew_conversation_id, responsible_subject_id, sender_kind, sender_member_id, sender_session_id, recipient_session_id, message_kind, summary, payload, status, created_at, read_at')
    .eq('recipient_session_id', sessionId)
    .order('created_at', { ascending: true })
    .limit(200);
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ items: data ?? [] });
});

crewRoutes.get('/', requireSubjectAuth(['crew:read']), async (c) => {
  const supa = c.var.authKind === 'device_grant' ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);
  const limitParam = Number.parseInt(c.req.query('limit') ?? '', 10);
  const limit = Math.min(Math.max(Number.isFinite(limitParam) ? limitParam : 50, 1), 100);

  let metaQuery = supa
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, status, title, runtime_location, created_at, updated_at')
    .eq('temporary_kind', 'crew')
    .order('created_at', { ascending: false });
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    metaQuery = metaQuery.eq('responsible_subject_id', deviceGrant.subjectId);
  }
  const { data: metaRows, error } = await metaQuery.limit(limit);
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
        runtime_location: typeof meta.runtime_location === 'string' ? meta.runtime_location : 'local_host',
        created_at: meta.created_at,
        updated_at: meta.updated_at ?? conv?.updated_at ?? meta.created_at,
      };
    }),
  });
});
