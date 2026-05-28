// T4.1 P1 — Session ↔ crew 群聊通信 HTTP 层(spec v2 §9)。
//
// 三个端点,挂在 /v1 下:
//
//   POST /v1/crews/:crewId/messages
//       人类用户(或带 device-grant 的代理)往 crew 群聊发一条消息。
//       Body 支持 spec v2 §9.2 的统一 @ 体验:
//         { content, mentions: [
//             { kind: 'human'|'session'|'captain'|'broadcast', target_id?: string }
//           ], message_kind?: 'text'|'system' }
//       - `@session <id>`           → 仅那个 session 的 mailbox
//       - `@captain`                → captain bot 持有的 active session(若有)
//       - `@broadcast` 或无 @       → 全 crew sessions(原 announcement
//                                      fan-out 默认行为)
//       - `@human`                  → mention 仅做元数据,不会 enqueue
//                                      (人类自己在群聊里看,不进 mailbox)
//       内部走 create_crew_announcement —— 复用现有 fan-out + visibility
//       校验。recipient_session_ids 由 mentions 解析得到。
//
//   GET  /v1/sessions/:sessionId/inbox
//       Session 启动 / 每轮 fresh prompt 前拉的"上下文包":
//         { whiteboard, mailbox, crew, session }
//       whiteboard = get_crew_whiteboard(crew_id) 整白板
//       mailbox    = 该 session 未 delivered/processed 的 mailbox 行
//       crew       = crew metadata(title / captain / runtime / shares)
//       session    = session 本身的 metadata(task_brief / status / ...)
//       接受 device-grant(runner host 拿)或 supabase JWT(主控端拿)。
//       device-grant 要求 subject 匹配 session 的 responsible subject;
//       supabase JWT 要求 user 是 crew member。
//
//   POST /v1/sessions/:sessionId/inbox/mark-delivered
//       Body: { item_ids: string[] }
//       走 RPC mark_session_mailbox_delivered。同上权限要求。
//
// 设计要点:
//   * 这里不替代 /v1/crew/:id/announcements —— 那条更底层、参数更精细
//     (recipient_session_ids / recipient_member_ids 显式列表)。新端点
//     是更"用户思维"的封装:给前端的 @ mention UI 用。
//   * 老 mailbox 行可能用 status='unread'(老 vocab);新行还是 'unread'。
//     mark-delivered 把 status 推到 'delivered',双 vocab 之间过渡。
//   * 关于消息卡片落地到 messages 表:本期 *暂不* 写 messages 行 ——
//     crew_announcements 已经承担白板事实源,messages 表语义保留给"普通
//     用户对话"。如果以后 iOS Crew Tab v2 要把 crew 群聊渲染成同一种
//     bubble UI,可以做 announcements ↔ messages 的视图层映射,而不是
//     双写。

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSubjectAuth } from '../lib/device-grants';
import { serviceClient, userClient, type SupabaseClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

// schema.ts hasn't been regenerated against this branch's migration yet
// (the main session applies the DB push + regen). Cast the RPC surface
// loose so we can call get_crew_whiteboard / enqueue_session_mailbox /
// mark_session_mailbox_delivered without typecheck noise. Once schema.ts
// is regen'd the casts become no-ops we can remove (or leave —
// supabase-js's generic .rpc<unknown> form is happy with both).
type UntypedRpcClient = {
  rpc: (
    name: string,
    args?: Record<string, unknown>,
  ) => Promise<{ data: unknown; error: { message: string; code?: string } | null }>;
};
function untypedRpc(client: SupabaseClient): UntypedRpcClient {
  return client as unknown as UntypedRpcClient;
}

export const crewMessagesRoutes = new Hono<AppBindings>();
export const sessionInboxRoutes = new Hono<AppBindings>();

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

// ────────────────────────────────────────────────────────────────────
// POST /v1/crews/:crewId/messages
// ────────────────────────────────────────────────────────────────────

const MentionItem = z.object({
  kind: z.enum(['human', 'session', 'captain', 'broadcast']),
  target_id: z.string().uuid().optional(),
});

const CrewMessageBody = z.object({
  content: z.string().trim().min(1).max(4_000),
  mentions: z.array(MentionItem).max(64).default([]),
  message_kind: z.enum(['text', 'system']).default('text'),
  // Optional opaque payload that the caller wants delivered alongside the
  // text (e.g. attachment refs, structured action data). Kept under the
  // hood as crew_announcements.payload.
  payload: z.record(z.string(), z.unknown()).optional(),
});

/// Translate the spec-v2 mention shape into recipient_session_ids the
/// existing RPC understands. Returns:
///   - `null` if everyone should receive (no @ or @broadcast)
///   - explicit array of session UUIDs otherwise
async function resolveRecipientSessions(
  env: AppBindings['Bindings'],
  crewId: string,
  mentions: z.infer<typeof MentionItem>[],
): Promise<{ sessionIds: string[] | null; error?: { status: number; message: string } }> {
  // No mentions, or any @broadcast, fan-out to everyone.
  if (mentions.length === 0 || mentions.some((m) => m.kind === 'broadcast')) {
    return { sessionIds: null };
  }

  const explicit = new Set<string>();
  const wantsCaptain = mentions.some((m) => m.kind === 'captain');

  for (const m of mentions) {
    if (m.kind === 'session') {
      if (!m.target_id) {
        return { sessionIds: [], error: { status: 400, message: 'session mention requires target_id' } };
      }
      explicit.add(m.target_id);
    }
    // 'human' mentions are metadata-only (the human reads the group,
    // they don't have a mailbox). Skip.
    // 'captain' resolved below.
  }

  if (wantsCaptain) {
    const svc = serviceClient(env);
    const { data: meta, error: metaErr } = await svc
      .from('temporary_group_meta')
      .select('captain_bot_id')
      .eq('conversation_id', crewId)
      .eq('temporary_kind', 'crew')
      .maybeSingle();
    if (metaErr) {
      return { sessionIds: [], error: { status: 500, message: metaErr.message } };
    }
    if (meta?.captain_bot_id) {
      // The captain's session is the one assigned to the captain bot's
      // crew member row. Find member, then session.
      const { data: memberRow, error: memberErr } = await svc
        .from('temporary_group_members')
        .select('id')
        .eq('conversation_id', crewId)
        .eq('bot_id', meta.captain_bot_id)
        .eq('status', 'active')
        .maybeSingle();
      if (memberErr) return { sessionIds: [], error: { status: 500, message: memberErr.message } };
      if (memberRow?.id) {
        const { data: sessionRows, error: sessErr } = await svc
          .from('crew_sessions')
          .select('id, status')
          .eq('crew_conversation_id', crewId)
          .eq('assigned_to_member_id', memberRow.id)
          .in('status', ['queued', 'running', 'waiting_permission', 'blocked']);
        if (sessErr) return { sessionIds: [], error: { status: 500, message: sessErr.message } };
        for (const s of sessionRows ?? []) {
          explicit.add(s.id);
        }
      }
    }
    // captain bot has no active session → drop the mention silently;
    // the message still lands on the whiteboard, just no mailbox push.
  }

  return { sessionIds: Array.from(explicit) };
}

crewMessagesRoutes.post('/:crewId/messages', requireSubjectAuth(['crew:write']), async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  let parsed: z.infer<typeof CrewMessageBody>;
  try {
    parsed = CrewMessageBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Spec v2 §9.5 lists `text` vs `system` as the user-facing message_kind,
  // but the crew_announcements check constraint expects one of the longer
  // enum {announcement, instruction, status, ...}. We map:
  //   * text   → instruction (default user message)
  //   * system → announcement (system / meta message, e.g. crew kickoff)
  const dbMessageKind = parsed.message_kind === 'system' ? 'announcement' : 'instruction';

  // Resolve mentions → recipient_session_ids
  const resolution = await resolveRecipientSessions(c.env, crewId, parsed.mentions);
  if (resolution.error) {
    if (resolution.error.status === 400) {
      return jsonError(c, 400, 'invalid_body', { message: resolution.error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: resolution.error.message });
  }
  const recipientSessionIds = resolution.sessionIds ?? [];

  // Capture the structured payload — content goes in summary, structured
  // bits go in payload.mentions / payload.extra so downstream consumers
  // (iOS Crew Tab, runner injectors) can rebuild the original shape.
  const payload: Record<string, unknown> = {
    text: parsed.content,
    mentions: parsed.mentions,
    user_message_kind: parsed.message_kind,
  };
  if (parsed.payload) payload.extra = parsed.payload;

  // Route through device-grant vs JWT branches mirroring crew.ts shape.
  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant?.grantedByUserId) return jsonError(c, 403, 'forbidden');
    const { data, error } = await serviceClient(c.env).rpc('create_crew_announcement_for_subject', {
      p_crew_conversation_id: crewId,
      p_responsible_subject_id: deviceGrant.subjectId,
      p_actor_user_id: deviceGrant.grantedByUserId,
      p_recipient_session_ids: recipientSessionIds as Json,
      p_recipient_member_ids: [] as Json,
      p_message_kind: dbMessageKind,
      p_summary: parsed.content,
      p_payload: payload as Json,
      p_board_visible: true,
    } as never);
    if (error) {
      const message = rpcMessage(error);
      if (/forbidden|not an active crew member/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
      if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
      if (/invalid|required|recipient/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    return c.json({ announcementId: data, recipientSessionIds });
  }

  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('create_crew_announcement', {
    p_crew_conversation_id: crewId,
    p_recipient_session_ids: recipientSessionIds as Json,
    p_recipient_member_ids: [] as Json,
    p_message_kind: dbMessageKind,
    p_summary: parsed.content,
    p_payload: payload as Json,
    p_board_visible: true,
  });
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    if (/forbidden|not an active crew member/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
    if (/invalid|required|recipient/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({ announcementId: data, recipientSessionIds });
});

// ────────────────────────────────────────────────────────────────────
// GET /v1/sessions/:sessionId/inbox
// ────────────────────────────────────────────────────────────────────

/// Pull the whiteboard + per-session mailbox tail + crew metadata in a
/// single call so the PendingCrew runner has everything it needs to
/// build the next prompt context.
sessionInboxRoutes.get('/:sessionId/inbox', requireSubjectAuth(['crew:read']), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });
  }
  const sinceParam = c.req.query('since');
  if (sinceParam && Number.isNaN(Date.parse(sinceParam))) {
    return jsonError(c, 400, 'invalid_query', { message: 'since must be ISO-8601 timestamp' });
  }

  // Resolve session row & gate the caller.
  const svc = serviceClient(c.env);
  const { data: sessionRow, error: sessionErr } = await svc
    .from('crew_sessions')
    .select('id, crew_conversation_id, responsible_subject_id, runner_host_id, runner_kind, status, task_brief, progress_summary, last_context_cursor, started_at, finished_at, created_at, updated_at, assigned_to_member_id, initiating_member_id')
    .eq('id', sessionId)
    .maybeSingle();
  if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
  if (!sessionRow) return jsonError(c, 404, 'session_not_found');

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    if (deviceGrant.subjectId !== sessionRow.responsible_subject_id) {
      return jsonError(c, 403, 'session_forbidden');
    }
  } else {
    // supabase_jwt branch: must be a crew member or owner of the subject.
    const userId = c.var.userId!;
    const { data: canView, error: canViewErr } = await svc.rpc('can_view_temporary_group', {
      p_conversation_id: sessionRow.crew_conversation_id,
      p_user_id: userId,
    });
    if (canViewErr) return jsonError(c, 500, 'database_error', { detail: canViewErr.message });
    if (canView !== true) return jsonError(c, 403, 'session_forbidden');
  }

  // Whiteboard
  const { data: whiteboard, error: wbErr } = await untypedRpc(svc).rpc('get_crew_whiteboard', {
    p_crew_id: sessionRow.crew_conversation_id,
    p_since: sinceParam ?? null,
  });
  if (wbErr) return jsonError(c, 500, 'database_error', { detail: wbErr.message });

  // Mailbox tail for this session — anything not yet processed.
  // We include unread / pending / delivered / read (legacy=unread, new
  // vocab=pending/delivered) so the runner sees what's actually new vs
  // what it already wrapped into a prior turn (status=processed/archived
  // = done).
  const { data: mailboxRows, error: mailErr } = await svc
    .from('session_mailbox_items')
    .select('id, crew_conversation_id, sender_kind, sender_member_id, sender_session_id, source_message_id, announcement_id, message_kind, summary, payload, status, created_at, delivered_at, read_at')
    .eq('recipient_session_id', sessionId)
    .in('status', ['unread', 'pending', 'delivered', 'read'])
    .order('created_at', { ascending: true })
    .limit(500);
  if (mailErr) return jsonError(c, 500, 'database_error', { detail: mailErr.message });

  // Crew metadata: members + captain + responsibility shares (the world-model
  // prompt template feeds on these).
  const { data: crewMeta, error: metaErr } = await svc
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, captain_bot_id, master_bot_id, runtime_kind, runtime_location, working_directory, tag, title, status, parent_temporary_group_id, root_temporary_group_id')
    .eq('conversation_id', sessionRow.crew_conversation_id)
    .maybeSingle();
  if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });

  const { data: members, error: memErr } = await svc
    .from('temporary_group_members')
    .select('id, member_kind, user_id, bot_id, code_session_id, display_name, role, status, represents_crew_id')
    .eq('conversation_id', sessionRow.crew_conversation_id)
    .eq('status', 'active');
  if (memErr) return jsonError(c, 500, 'database_error', { detail: memErr.message });

  const { data: shares, error: shareErr } = await svc
    .from('crew_responsibility_shares')
    .select('subject_id, share_bps, is_tiebreaker')
    .eq('crew_conversation_id', sessionRow.crew_conversation_id);
  if (shareErr) return jsonError(c, 500, 'database_error', { detail: shareErr.message });

  return c.json({
    session: sessionRow,
    crew: {
      meta: crewMeta,
      members: members ?? [],
      shares: shares ?? [],
    },
    whiteboard: whiteboard ?? [],
    mailbox: mailboxRows ?? [],
  });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/sessions/:sessionId/inbox/mark-delivered
// ────────────────────────────────────────────────────────────────────

const MarkDeliveredBody = z.object({
  item_ids: z.array(z.string().uuid()).min(1).max(500),
});

sessionInboxRoutes.post('/:sessionId/inbox/mark-delivered', requireSubjectAuth(['crew:write']), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });
  }
  let parsed: z.infer<typeof MarkDeliveredBody>;
  try {
    parsed = MarkDeliveredBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Same gate as GET — must own the session.
  const svc = serviceClient(c.env);
  const { data: sessionRow, error: sessionErr } = await svc
    .from('crew_sessions')
    .select('id, responsible_subject_id, crew_conversation_id')
    .eq('id', sessionId)
    .maybeSingle();
  if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
  if (!sessionRow) return jsonError(c, 404, 'session_not_found');

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    if (deviceGrant.subjectId !== sessionRow.responsible_subject_id) {
      return jsonError(c, 403, 'session_forbidden');
    }
    // Device-grant path → call the RPC under service-role; the RPC
    // skips auth.uid() check when called this way (caller_id=null).
    const { data, error } = await untypedRpc(svc).rpc('mark_session_mailbox_delivered', {
      p_session_id: sessionId,
      p_item_ids: parsed.item_ids,
    });
    if (error) {
      const message = rpcMessage(error);
      if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
      return jsonError(c, 500, 'database_error', { detail: message });
    }
    return c.json({ updated: data ?? 0 });
  }

  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await untypedRpc(supa).rpc('mark_session_mailbox_delivered', {
    p_session_id: sessionId,
    p_item_ids: parsed.item_ids,
  });
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    if (/forbidden/i.test(message)) return jsonError(c, 403, 'session_forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }
  return c.json({ updated: data ?? 0 });
});
