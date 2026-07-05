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
import { resolveOutboundRecipients } from '../lib/crew-outbound';

// ── messages → chat-entry mapping (spec §9: crew chat IS the conversation's
// `messages`, so the captain replies via the standard bot-reply pipeline and
// session cards / interaction cards ride the same stream). We map a messages
// row onto the existing whiteboard-entry wire shape so clients (PendingCrew
// CrewChatView + the runner's context digest) need no change.
type ChatMessageRow = {
  id: string;
  conversation_id: string;
  role: string;
  content: string | null;
  user_id: string | null;
  sender_bot_id: string | null;
  log_kind: string | null;
  log_payload: Record<string, unknown> | null;
  // `messages.attachments` jsonb. Worker writes `{ ids: [uuid, ...] }` on
  // insert (see routes/messages.ts) — NOT the full object array. We hydrate
  // those ids → renderable objects via `hydrateCrewAttachments` below.
  attachments: Json | null;
  created_at: string;
};

// One attachment as PendingCrew renders it (mirror of iOS `Attachment`):
// id + mime + the auth-gated `/v1/uploads/<id>` URL + display metadata.
// `kind` is "image" | "file"; the client also derives image-ness from `mime`.
type CrewWireAttachment = {
  id: string;
  kind: string;
  mime: string;
  size: number | null;
  width: number | null;
  height: number | null;
  url: string;
  filename: string | null;
};

// Pull `{ ids: [...] }` out of a messages.attachments jsonb cell. Tolerates
// the legacy/empty shapes (null, missing `ids`, non-array) → empty list.
function attachmentIdsOf(raw: Json | null): string[] {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return [];
  const ids = (raw as { ids?: unknown }).ids;
  if (!Array.isArray(ids)) return [];
  return ids.filter((x): x is string => typeof x === 'string');
}

// Batch-resolve every referenced attachment id across a set of messages into
// full renderable objects, keyed by message id. PendingCrew talks only to the
// edge (no direct Supabase), so the wire must carry mime/size/url/filename —
// we mirror exactly what PendingBot's iOS `MessagesFetch.attachmentMeta` builds
// (`url: /v1/uploads/<id>`), here server-side for the crew whiteboard.
async function hydrateCrewAttachments(
  svc: SupabaseClient,
  rows: ChatMessageRow[],
): Promise<Map<string, CrewWireAttachment[]>> {
  const out = new Map<string, CrewWireAttachment[]>();
  const perMessage = new Map<string, string[]>();
  const allIds = new Set<string>();
  for (const r of rows) {
    const ids = attachmentIdsOf(r.attachments);
    if (ids.length === 0) continue;
    perMessage.set(r.id, ids);
    for (const id of ids) allIds.add(id);
  }
  if (allIds.size === 0) return out;

  const { data: attRows, error } = await svc
    .from('attachments')
    .select('id, mime_type, filename, byte_size, width, height')
    .in('id', Array.from(allIds));
  // Fail soft: a hydration error degrades to "no attachments" rather than
  // failing the whole whiteboard read. The chat text still renders.
  if (error || !attRows) return out;

  const metaById = new Map<string, CrewWireAttachment>();
  for (const a of attRows) {
    const mime = a.mime_type as string;
    metaById.set(a.id as string, {
      id: a.id as string,
      kind: mime.toLowerCase().startsWith('image/') ? 'image' : 'file',
      mime,
      size: (a.byte_size as number | null) ?? null,
      width: (a.width as number | null) ?? null,
      height: (a.height as number | null) ?? null,
      url: `/v1/uploads/${a.id}`,
      filename: (a.filename as string | null) ?? null,
    });
  }

  for (const [msgId, ids] of perMessage) {
    const resolved = ids
      .map((id) => metaById.get(id))
      .filter((x): x is CrewWireAttachment => x != null);
    if (resolved.length > 0) out.set(msgId, resolved);
  }
  return out;
}

// Resolved sender identity for a single row (Phase 3 — the whiteboard should
// show *who* posted, not a bare uuid). Computed once per request from the crew
// roster (see `resolveSender` below) and threaded into `mapMessageToEntry`.
type SenderIdentity = {
  senderName: string | null;
  senderMemberId: string | null;
};

export function mapMessageToEntry(
  m: ChatMessageRow,
  resolvedAttachments?: CrewWireAttachment[],
  sender?: SenderIdentity,
): Record<string, unknown> {
  const lp = (m.log_payload ?? {}) as Record<string, unknown>;
  // 接合 v2 block 3:Mac relay 上行的来源标注落在 attachments jsonb 上
  // ({ origin: 'mac_relay', senderLabel?, localSessionId?, ids? })。读取侧
  // 原样透出,Mac 同步代理靠它做回环防护(过滤自己推上去的条目)。
  let relay: Record<string, unknown> | null = null;
  if (m.attachments && typeof m.attachments === 'object' && !Array.isArray(m.attachments)) {
    const a = m.attachments as { origin?: unknown; senderLabel?: unknown; localSessionId?: unknown };
    if (typeof a.origin === 'string') {
      relay = {
        origin: a.origin,
        senderLabel: typeof a.senderLabel === 'string' ? a.senderLabel : null,
        localSessionId: typeof a.localSessionId === 'string' ? a.localSessionId : null,
      };
    }
  }
  // #377 — 统一透出 in_reply_to(被回复消息的 id)。两个载体:
  //   * 人类消息 → attachments jsonb 的 `in_reply_to`(POST /messages 落)。
  //   * session 帖 → log_payload.in_reply_to(post-to-crew 镜像消息落)。
  // 读不出 → null。客户端据此本地在已加载 entries 里按 id 查被引用消息渲染。
  let inReplyTo: string | null = null;
  if (m.attachments && typeof m.attachments === 'object' && !Array.isArray(m.attachments)) {
    const a = m.attachments as { in_reply_to?: unknown };
    if (typeof a.in_reply_to === 'string') inReplyTo = a.in_reply_to;
  }
  if (inReplyTo == null && typeof lp.in_reply_to === 'string') {
    inReplyTo = lp.in_reply_to;
  }
  const senderKind =
    m.role === 'user' || m.role === 'human' ? 'user'
    : m.role === 'bot' || m.role === 'assistant' ? 'bot'
    : m.role === 'log' ? 'session'
    : m.role;
  // For log rows (cards) the payload IS the card; for prose the text is content.
  // 非 log 行也可能挂结构化 payload(#242 task_request:role='user' +
  // log_kind='task_request' + log_payload=指令体)—— 合并透出,text 保底。
  const payload =
    m.role === 'log' ? lp : { text: m.content ?? '', ...lp };
  const sessionId = typeof lp.session_id === 'string' ? lp.session_id : null;
  return {
    id: m.id,
    crew_conversation_id: m.conversation_id,
    sender_kind: senderKind,
    sender_user_id: senderKind === 'user' ? m.user_id : null,
    sender_bot_id: senderKind === 'bot' ? m.sender_bot_id : null,
    sender_session_id: sessionId,
    message_kind: m.log_kind ?? 'text',
    summary: m.content ?? (typeof lp.question === 'string' ? lp.question : null),
    payload,
    // Renderable attachment objects (hydrated from messages.attachments
    // `{ ids: [...] }`). null when the message has none.
    attachments: resolvedAttachments && resolvedAttachments.length > 0 ? resolvedAttachments : null,
    // Mac relay 来源标记(null = 非 relay 上行)。
    relay,
    // Phase 3 — 发送者显示名(+ 成员 id),由 caller 经 roster map 解析后传入;
    // 解析不出 → null,客户端退回现有渲染(裸 session/人类),不报错。relay 上行
    // 自带 senderLabel(远端真名)时优先用它,免再查 roster。
    sender_display_name: sender?.senderName ?? (relay?.senderLabel as string | null | undefined) ?? null,
    sender_member_id: sender?.senderMemberId ?? null,
    // #377 — 被回复消息的 id(无 → null)。客户端在已加载 entries 里本地查它的
    // 发送者 + 内容摘要,渲染成引用条。
    in_reply_to: inReplyTo,
    created_at: m.created_at,
  };
}

// One crew roster row needed to resolve a message's sender display name. We
// only pull the columns the resolver maps on (member id + the two id columns +
// display_name), keyed once per request so reads don't go N+1.
type RosterRow = {
  id: string;
  member_kind: string | null;
  user_id: string | null;
  code_session_id: string | null;
  display_name: string | null;
};

// Build a sender resolver from a crew's active members. Returns a closure that
// maps a `ChatMessageRow` → { senderName, senderMemberId }:
//   * human prose (role user/human, has user_id) → member with that user_id
//   * session post  (role log, log_payload.session_id) → code_session member
//     with that code_session_id
// Anything else (bot replies, unmatched ids) → nulls. Bot display names are
// intentionally left to the client (it already knows the captain), so we only
// resolve the two cases the bare-uuid problem actually bites.
function makeSenderResolver(members: RosterRow[] | null | undefined): (m: ChatMessageRow) => SenderIdentity {
  const byUserId = new Map<string, RosterRow>();
  const bySessionId = new Map<string, RosterRow>();
  for (const mem of members ?? []) {
    if (mem.user_id && !byUserId.has(mem.user_id)) byUserId.set(mem.user_id, mem);
    if (mem.code_session_id && !bySessionId.has(mem.code_session_id)) bySessionId.set(mem.code_session_id, mem);
  }
  return (m: ChatMessageRow): SenderIdentity => {
    if ((m.role === 'user' || m.role === 'human') && m.user_id) {
      const mem = byUserId.get(m.user_id);
      if (mem) return { senderName: mem.display_name ?? null, senderMemberId: mem.id };
    } else if (m.role === 'log') {
      const lp = (m.log_payload ?? {}) as Record<string, unknown>;
      const sid = typeof lp.session_id === 'string' ? lp.session_id : null;
      if (sid) {
        const mem = bySessionId.get(sid);
        if (mem) return { senderName: mem.display_name ?? null, senderMemberId: mem.id };
      }
    }
    return { senderName: null, senderMemberId: null };
  };
}

// Fetch the crew's active roster (the rows the sender resolver needs) in one
// query. Fail-soft: on error return [] so a roster hiccup degrades to "no
// display names" rather than failing the whole whiteboard read.
async function fetchRoster(svc: SupabaseClient, crewId: string): Promise<RosterRow[]> {
  const { data, error } = await svc
    .from('temporary_group_members')
    .select('id, member_kind, user_id, code_session_id, display_name')
    .eq('conversation_id', crewId)
    .eq('status', 'active');
  if (error || !data) return [];
  return data as unknown as RosterRow[];
}
const CHAT_ROLES = ['user', 'human', 'bot', 'assistant', 'log'];
const CHAT_SELECT = 'id, conversation_id, role, content, user_id, sender_bot_id, log_kind, log_payload, attachments, created_at';

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
  // 'task_request'(#242 遥控 v1):iOS 在 relay crew 里发结构化指令
  // ({ action:'run_session', runner_kind?, task_brief })。落 messages 行的
  // log_kind/log_payload(role 仍 'user'),Mac CrewRelayAgent 拉取后本地起 session。
  message_kind: z.enum(['text', 'system', 'task_request']).default('text'),
  // Optional opaque payload that the caller wants delivered alongside the
  // text (e.g. attachment refs, structured action data). Kept under the
  // hood as crew_announcements.payload.
  payload: z.record(z.string(), z.unknown()).optional(),
  // Attachment ids already uploaded via POST /v1/upload (device-grant path).
  // Stored on the messages row as `{ ids: [...] }` (mirror routes/messages.ts)
  // and hydrated → full renderable objects on read by hydrateCrewAttachments.
  attachmentIds: z.array(z.string().uuid()).max(16).optional(),
  // 接合 v2 block 3:Mac relay 代发本地 captain/session 话语时的来源标注。
  // 仅 device-grant 路径生效;落进 attachments jsonb 并强制带
  // origin:'mac_relay',Mac 拉取侧靠它过滤自己的上行(回环防护在客户端)。
  senderLabel: z.string().trim().min(1).max(64).optional(),
  localSessionId: z.string().trim().min(1).max(64).optional(),
  // #377 — "回复某条消息"的可见引用。被回复消息的白板 id。沿用 jsonb 方案
  // (不加列):落进该人类消息的 attachments jsonb 的 `in_reply_to`(与 Phase 2
  // session 帖 log_payload.in_reply_to 同语义,统一经 mapMessageToEntry 透出
  // entry.in_reply_to)。自动 @ 原发送者由客户端 staged mention 走通,服务端
  // 不在这重复解析。非法 uuid → zod 挡;指向同 crew 不存在的消息 → 400(与
  // Phase 2 resolveOutboundRecipients 对 reply_to 的严格度一致)。
  reply_to: z.string().uuid().optional(),
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

  const svc = serviceClient(c.env);
  const { data: meta, error: metaErr } = await svc
    .from('temporary_group_meta')
    .select('responsible_subject_id')
    .eq('conversation_id', crewId)
    .maybeSingle();
  if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });
  if (!meta) return jsonError(c, 404, 'not_found', { message: 'crew not found' });

  // Resolve + gate the caller (the human posting in the crew group chat).
  let callerUserId: string | null = null;
  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg?.grantedByUserId) return jsonError(c, 403, 'forbidden');
    if (dg.subjectId !== meta.responsible_subject_id) return jsonError(c, 403, 'forbidden');
    callerUserId = dg.grantedByUserId;
  } else {
    callerUserId = c.var.userId ?? null;
    if (!callerUserId) return jsonError(c, 401, 'unauthorized');
    const { data: canView, error: canViewErr } = await svc.rpc('can_view_temporary_group', {
      p_conversation_id: crewId,
      p_user_id: callerUserId,
    });
    if (canViewErr) return jsonError(c, 500, 'database_error', { detail: canViewErr.message });
    if (canView !== true) return jsonError(c, 403, 'forbidden');
  }

  // #377 — reply_to 存在性校验(uuid 形已由 zod 挡)。给了就查同 crew 有没有
  // 这条;没有 → 400(与 Phase 2 resolveOutboundRecipients 对 reply_to 的严格度
  // 一致 —— 指向不存在的消息是 malformed 请求)。校验放 insert 前,坏 reply_to
  // 不落消息。
  if (parsed.reply_to) {
    const { data: replied, error: repliedErr } = await svc
      .from('messages')
      .select('id')
      .eq('id', parsed.reply_to)
      .eq('conversation_id', crewId)
      .maybeSingle();
    if (repliedErr) return jsonError(c, 500, 'database_error', { detail: repliedErr.message });
    if (!replied) {
      return jsonError(c, 400, 'invalid_body', {
        message: 'reply_to points at a message that does not exist in this crew',
      });
    }
  }

  // spec §9: the crew chat IS the conversation's `messages`. Insert the human's
  // message, then enqueue it into the mailbox of each recipient crew session so
  // the local runner picks it up (本地为家:edge 是邮差,不在 edge 唤醒 bot 回合).
  const messageId = crypto.randomUUID();
  // attachments jsonb 同时承载附件 ids 与 relay 来源标注(最小侵入:不加列、
  // 不改 log 卡机制)。Mac relay 上行(device-grant + senderLabel/localSessionId)
  // 一律打上 origin:'mac_relay';读取侧 mapMessageToEntry 透出为 entry.relay。
  const isMacRelay =
    c.var.authKind === 'device_grant' && (parsed.senderLabel != null || parsed.localSessionId != null);
  let attachmentsCell: Record<string, unknown> | null = parsed.attachmentIds?.length
    ? { ids: parsed.attachmentIds }
    : null;
  if (isMacRelay) {
    attachmentsCell = {
      ...(attachmentsCell ?? {}),
      origin: 'mac_relay',
      ...(parsed.senderLabel ? { senderLabel: parsed.senderLabel } : {}),
      ...(parsed.localSessionId ? { localSessionId: parsed.localSessionId } : {}),
    };
  }
  // #377 — 把 reply_to 的可见引用落进同一个 attachments jsonb 载体(与附件
  // ids / relay 标注共存,不加列)。读取侧 mapMessageToEntry 透出 entry.in_reply_to。
  if (parsed.reply_to) {
    attachmentsCell = { ...(attachmentsCell ?? {}), in_reply_to: parsed.reply_to };
  }
  // task_request:kind 落 log_kind、结构化指令落 log_payload(role 仍 'user',
  // 在群聊时间线上以发送者本人的气泡呈现)。读取侧 mapMessageToEntry 把
  // log_payload 合并进 entry.payload,Mac 拉取后据此本地起 session。
  const isTaskRequest = parsed.message_kind === 'task_request';
  const { error: insErr } = await svc.from('messages').insert({
    id: messageId,
    client_message_id: crypto.randomUUID(),
    conversation_id: crewId,
    user_id: callerUserId,
    role: 'user',
    content: parsed.content,
    status: 'done',
    ...(isTaskRequest
      ? { log_kind: 'task_request', log_payload: (parsed.payload ?? {}) as Json }
      : {}),
    // Mirror routes/messages.ts: persist attachment refs as `{ ids: [...] }`
    // (null when none) so hydrateCrewAttachments can resolve them on read.
    attachments: attachmentsCell,
  } as never);
  if (insErr) return jsonError(c, 500, 'database_error', { detail: insErr.message });

  // Directed mailbox fan-out (spec v2 §9.2 @ experience). @session / @captain
  // resolve to explicit recipient session ids; each gets ONE directed mailbox
  // row in addition to the broadcast above (the message already lives in
  // `messages` for everyone). @broadcast / no @ → sessionIds === null → skip.
  const recip = await resolveRecipientSessions(c.env, crewId, parsed.mentions);
  if (recip.error) {
    // A validation error (e.g. a session mention without target_id) is a
    // malformed request — surface it. The message row already landed, but the
    // caller should learn their @ was rejected. DB-level errors are NOT fatal
    // (the broadcast succeeded); only 4xx validation errors bubble up.
    if (recip.error.status >= 400 && recip.error.status < 500) {
      return jsonError(c, 400, 'invalid_body', { message: recip.error.message });
    }
    console.warn('[crew] resolveRecipientSessions error', recip.error.message);
  } else if (recip.sessionIds && recip.sessionIds.length > 0) {
    // Best-effort: a mailbox enqueue failure must NOT fail the request — the
    // message insert is the source of truth and the broadcast already happened.
    for (const targetSessionId of recip.sessionIds) {
      const { error: enqErr } = await untypedRpc(svc).rpc('enqueue_session_mailbox', {
        p_session_id: targetSessionId,
        p_message_kind: 'instruction',
        p_summary: parsed.content,
        p_payload: { source: 'crew_mention' },
        p_source_message_id: messageId,
      });
      if (enqErr) {
        console.warn('[crew] enqueue_session_mailbox failed', targetSessionId, enqErr.message);
      }
    }
  }

  return c.json({ messageId });
});

// ────────────────────────────────────────────────────────────────────
// GET /v1/crews/:crewId/messages
// ────────────────────────────────────────────────────────────────────
//
// Crew-level whiteboard for the PendingCrew Mac middle pane (spec §9 群聊会话
// 页). Returns the full whiteboard (get_crew_whiteboard) so the chat timeline
// can render it. crewId == crew_conversation_id. Gated like the session inbox:
// device-grant subject must own the crew; JWT user must be able to view it.
crewMessagesRoutes.get('/:crewId/messages', requireSubjectAuth(['crew:read']), async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  const sinceParam = c.req.query('since');
  if (sinceParam && Number.isNaN(Date.parse(sinceParam))) {
    return jsonError(c, 400, 'invalid_query', { message: 'since must be ISO-8601 timestamp' });
  }

  const svc = serviceClient(c.env);

  // Resolve the crew's responsible subject for the device-grant gate.
  const { data: meta, error: metaErr } = await svc
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, captain_bot_id, title, working_directory, runtime_location, status')
    .eq('conversation_id', crewId)
    .maybeSingle();
  if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });
  if (!meta) return jsonError(c, 404, 'not_found', { message: 'crew not found' });

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    if (deviceGrant.subjectId !== meta.responsible_subject_id) {
      return jsonError(c, 403, 'forbidden');
    }
  } else {
    const userId = c.var.userId!;
    const { data: canView, error: canViewErr } = await svc.rpc('can_view_temporary_group', {
      p_conversation_id: crewId,
      p_user_id: userId,
    });
    if (canViewErr) return jsonError(c, 500, 'database_error', { detail: canViewErr.message });
    if (canView !== true) return jsonError(c, 403, 'forbidden');
  }

  // spec §9: the crew group chat IS the conversation's `messages` (human prose
  // + captain replies + session cards + interaction cards), mapped onto the
  // chat-entry shape. Access gated above.
  let q = svc
    .from('messages')
    .select(CHAT_SELECT)
    .eq('conversation_id', crewId)
    .in('role', CHAT_ROLES)
    .neq('status', 'deleted');
  if (sinceParam) q = q.gte('created_at', sinceParam);
  const { data: rows, error: msgErr } = await q.order('created_at', { ascending: true }).limit(500);
  if (msgErr) return jsonError(c, 500, 'database_error', { detail: msgErr.message });
  const chatRows = (rows ?? []) as unknown as ChatMessageRow[];
  const attByMsg = await hydrateCrewAttachments(svc, chatRows);
  // Phase 3 — resolve sender display names off the roster (one query, no N+1).
  const resolveSender = makeSenderResolver(await fetchRoster(svc, crewId));
  const whiteboard = chatRows.map((r) => mapMessageToEntry(r, attByMsg.get(r.id), resolveSender(r)));

  // 接合 v2 block 3:lastCursor = 本批最大 created_at(rows 升序 → 末行),
  // Mac 同步代理存成 relayCursor,下次 `?since=` 续传;空批返回 null。
  const lastCursor = chatRows.length > 0 ? chatRows[chatRows.length - 1].created_at : null;

  return c.json({ crewId, whiteboard, lastCursor });
});

// ────────────────────────────────────────────────────────────────────
// GET /v1/crews/:crewId/members
// ────────────────────────────────────────────────────────────────────
//
// The crew's roster for the middle-pane group chat (spec §9 — everyone is a
// member: human / captain / code_session / temp bot). crewId ==
// crew_conversation_id. Same gate as the whiteboard GET.
crewMessagesRoutes.get('/:crewId/members', requireSubjectAuth(['crew:read']), async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }

  const svc = serviceClient(c.env);
  const { data: meta, error: metaErr } = await svc
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, captain_bot_id')
    .eq('conversation_id', crewId)
    .maybeSingle();
  if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });
  if (!meta) return jsonError(c, 404, 'not_found', { message: 'crew not found' });

  if (c.var.authKind === 'device_grant') {
    const deviceGrant = c.var.deviceGrant;
    if (!deviceGrant) return jsonError(c, 401, 'unauthorized');
    if (deviceGrant.subjectId !== meta.responsible_subject_id) {
      return jsonError(c, 403, 'forbidden');
    }
  } else {
    const userId = c.var.userId!;
    const { data: canView, error: canViewErr } = await svc.rpc('can_view_temporary_group', {
      p_conversation_id: crewId,
      p_user_id: userId,
    });
    if (canViewErr) return jsonError(c, 500, 'database_error', { detail: canViewErr.message });
    if (canView !== true) return jsonError(c, 403, 'forbidden');
  }

  const { data: membersRaw, error: memErr } = await svc
    .from('temporary_group_members')
    .select('id, member_kind, user_id, bot_id, code_session_id, display_name, role, status, represents_crew_id, created_at')
    .eq('conversation_id', crewId)
    .eq('status', 'active')
    .order('created_at', { ascending: true });
  if (memErr) return jsonError(c, 500, 'database_error', { detail: memErr.message });
  const members = membersRaw ?? [];

  // Drop code_session members whose session is terminal, so finished sessions
  // fall out of the roster without having to deactivate the member on finish.
  // Also surface the live session status so the UI can badge running ones.
  const sessionIds = members
    .filter((m) => m.member_kind === 'code_session' && m.code_session_id)
    .map((m) => m.code_session_id as string);
  const statusById = new Map<string, string>();
  if (sessionIds.length > 0) {
    const { data: sessRows, error: sessErr } = await svc
      .from('crew_sessions')
      .select('id, status')
      .in('id', sessionIds);
    if (sessErr) return jsonError(c, 500, 'database_error', { detail: sessErr.message });
    for (const s of sessRows ?? []) statusById.set(s.id, s.status);
  }
  const TERMINAL = new Set(['completed', 'failed', 'cancelled']);
  const visible = members
    .filter((m) => {
      if (m.member_kind !== 'code_session') return true;
      const st = m.code_session_id ? statusById.get(m.code_session_id) : undefined;
      return st !== undefined && !TERMINAL.has(st);
    })
    .map((m) => ({
      ...m,
      sessionStatus: m.member_kind === 'code_session' && m.code_session_id
        ? statusById.get(m.code_session_id) ?? null
        : null,
    }));

  return c.json({ crewId, captainBotId: meta.captain_bot_id, members: visible });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/crews/:crewId/members
// ────────────────────────────────────────────────────────────────────
//
// 接合 v2 block 3:成员邀请走 device grant(或 JWT)。Mac「接入 PendingBot」
// 后从本地把 PendingBot 侧的 bot / 人类账号拉进 relay crew conversation。
// 校验全在 RPC crew_add_member_for_subject 里(security definer):
//   * actor 能为 crew 的 responsible_subject 出面
//   * bot 须 actor 可用(自己的 bot 或经 user_bot_contacts 加过的公有 bot)
//   * human 须是 actor 好友(user_contacts)或 subject 成员
// 幂等:已是 active 成员则原样返回(不报错)。

const AddMemberBody = z.object({
  kind: z.enum(['bot', 'human']),
  botId: z.string().uuid().optional(),
  userId: z.string().uuid().optional(),
});

crewMessagesRoutes.post('/:crewId/members', requireSubjectAuth(['crew:write']), async (c) => {
  const crewId = c.req.param('crewId');
  if (!isUuid(crewId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'crewId must be a uuid' });
  }
  let parsed: z.infer<typeof AddMemberBody>;
  try {
    parsed = AddMemberBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  if (parsed.kind === 'bot' && !parsed.botId) {
    return jsonError(c, 400, 'invalid_body', { message: 'botId required when kind=bot' });
  }
  if (parsed.kind === 'human' && !parsed.userId) {
    return jsonError(c, 400, 'invalid_body', { message: 'userId required when kind=human' });
  }

  const svc = serviceClient(c.env);
  const { data: meta, error: metaErr } = await svc
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id')
    .eq('conversation_id', crewId)
    .eq('temporary_kind', 'crew')
    .maybeSingle();
  if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });
  if (!meta) return jsonError(c, 404, 'not_found', { message: 'crew not found' });

  // 与 POST /v1/crews 同款双轨:device grant → serviceClient + 显式 actor
  // (RPC COALESCE(auth.uid(), p_actor_user_id));JWT → userClient,auth.uid()
  // 驱动 RPC,传入的 actor 被忽略,无法冒充。
  let actorUserId: string;
  if (c.var.authKind === 'device_grant') {
    const dg = c.var.deviceGrant;
    if (!dg?.grantedByUserId) return jsonError(c, 403, 'forbidden');
    if (dg.subjectId !== meta.responsible_subject_id) return jsonError(c, 403, 'forbidden');
    actorUserId = dg.grantedByUserId;
  } else {
    const userId = c.var.userId;
    if (!userId) return jsonError(c, 401, 'unauthorized');
    actorUserId = userId;
  }
  const supa = c.var.authKind === 'device_grant' ? svc : userClient(c.env, c.var.userJwt!);

  const { data, error } = await untypedRpc(supa).rpc('crew_add_member_for_subject', {
    p_actor_user_id: actorUserId,
    p_crew_conversation_id: crewId,
    p_member_kind: parsed.kind === 'bot' ? 'registered_bot' : 'human',
    p_bot_id: parsed.botId ?? null,
    p_user_id: parsed.userId ?? null,
  });
  if (error) {
    const message = rpcMessage(error);
    const code = (error as { code?: string }).code ?? null;
    if (code === '28000' || /authentication required/i.test(message)) {
      return jsonError(c, 401, 'unauthorized', { message });
    }
    if (code === '42501' || /forbidden|not a friend|not visible|not invited/i.test(message)) {
      return jsonError(c, 403, 'forbidden', { message });
    }
    if (code === 'P0002' || /not found/i.test(message)) {
      return jsonError(c, 404, 'not_found', { message });
    }
    if (code === '22023' || /invalid|required|inactive/i.test(message)) {
      return jsonError(c, 400, 'invalid_body', { message });
    }
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  // RPC 返回成员行摘要 jsonb(含 already_member 标记);幂等命中也 201,
  // 客户端不必区分"新加"还是"已在"。
  return c.json({ crewId, member: data }, 201);
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

  // Crew roster, fetched up front so it doubles as the sender-name resolver for
  // the whiteboard (Phase 3) AND the crew.members payload below — one query, no
  // N+1. Superset of RosterRow (adds bot_id / role / represents_crew_id for the
  // world-model template).
  const { data: members, error: memErr } = await svc
    .from('temporary_group_members')
    .select('id, member_kind, user_id, bot_id, code_session_id, display_name, role, status, represents_crew_id')
    .eq('conversation_id', sessionRow.crew_conversation_id)
    .eq('status', 'active');
  if (memErr) return jsonError(c, 500, 'database_error', { detail: memErr.message });
  const resolveSender = makeSenderResolver((members ?? []) as unknown as RosterRow[]);

  // Whiteboard = the crew conversation's `messages` (spec §9 unified store), so
  // the session's per-turn context injection sees the human chat + captain
  // replies + cards. Mapped onto the chat-entry shape; access gated above.
  let wbQuery = svc
    .from('messages')
    .select(CHAT_SELECT)
    .eq('conversation_id', sessionRow.crew_conversation_id)
    .in('role', CHAT_ROLES)
    .neq('status', 'deleted');
  if (sinceParam) wbQuery = wbQuery.gte('created_at', sinceParam);
  const { data: wbRows, error: wbErr } = await wbQuery
    .order('created_at', { ascending: true })
    .limit(500);
  if (wbErr) return jsonError(c, 500, 'database_error', { detail: wbErr.message });
  const wbChatRows = (wbRows ?? []) as unknown as ChatMessageRow[];
  const wbAttByMsg = await hydrateCrewAttachments(svc, wbChatRows);
  const whiteboard = wbChatRows.map((r) => mapMessageToEntry(r, wbAttByMsg.get(r.id), resolveSender(r)));

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
    .select('conversation_id, responsible_subject_id, captain_bot_id, master_bot_id, runtime_location, working_directory, title, status, parent_temporary_group_id, root_temporary_group_id')
    .eq('conversation_id', sessionRow.crew_conversation_id)
    .maybeSingle();
  if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });

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

const SessionPostToCrewBody = z.object({
  content: z.string().trim().min(1).max(4_000),
  category: z.enum(['progress', 'question', 'milestone']).optional(),
  // Phase 2 — outbound @ + reply_to. `mentions` reuses the spec-v2 mention
  // shape (only 'session' / 'human' are meaningful on an outbound post);
  // `reply_to` auto-@s the replied-to message's original sender. Both resolve
  // via lib/crew-outbound.ts:resolveOutboundRecipients.
  mentions: z.array(MentionItem).max(64).default([]),
  reply_to: z.string().uuid().optional(),
});

// T4.3 — server-side reception for the `request_permission` agent tool.
// Same auth shape as post-to-crew (device-grant only — only the runner
// owns the session lease and can speak on its behalf). Body mirrors the
// tool's args: action (1–400 char short string), details (free-form
// jsonb), risk_level (optional, 'low'|'medium'|'high', default medium).
const SessionRequestPermissionBody = z.object({
  action: z.string().trim().min(1).max(400),
  details: z.record(z.string(), z.unknown()).default({}),
  risk_level: z.enum(['low', 'medium', 'high']).optional(),
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/sessions/:sessionId/post-to-crew
//
// The server-side reception for spec v2 §9.3's `post_to_crew` tool when
// the agent (Claude Code / Codex) emits it inside a PendingCrew runner.
// The runner translates the tool-call into this HTTP POST.
//
// Auth: device-grant only — the runner host owns the grant and is the
// authoritative source for "this session emitted this tool call".
// Supabase JWT path is intentionally rejected — humans don't post via
// this endpoint, they use POST /v1/crews/:crewId/messages.
// ────────────────────────────────────────────────────────────────────

sessionInboxRoutes.post('/:sessionId/post-to-crew', requireSubjectAuth(['crew:write']), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });
  }
  if (c.var.authKind !== 'device_grant') {
    return jsonError(c, 403, 'forbidden', {
      message: 'post-to-crew requires a device grant (runner-only path)',
    });
  }
  const deviceGrant = c.var.deviceGrant!;

  let parsed: z.infer<typeof SessionPostToCrewBody>;
  try {
    parsed = SessionPostToCrewBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Resolve the session + its runner_host_id (needed by the runner-side
  // RPC for the lease check).
  const svc = serviceClient(c.env);
  const { data: sessionRow, error: sessionErr } = await svc
    .from('crew_sessions')
    .select('id, responsible_subject_id, runner_host_id, status, crew_conversation_id')
    .eq('id', sessionId)
    .maybeSingle();
  if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
  if (!sessionRow) return jsonError(c, 404, 'session_not_found');
  if (sessionRow.responsible_subject_id !== deviceGrant.subjectId) {
    return jsonError(c, 403, 'session_forbidden');
  }
  if (!sessionRow.runner_host_id) {
    return jsonError(c, 409, 'conflict', {
      message: 'session has no active runner host — cannot post on its behalf',
    });
  }

  // Phase 2 — resolve outbound @ + reply_to into explicit recipient lists.
  // @session / reply_to-of-a-session-post → session recipients (each gets a
  // directed mailbox row); reply_to-of-a-human-message → member recipient
  // (metadata-only, no mailbox). A malformed @ / reply_to is a 400.
  const recip = await resolveOutboundRecipients(
    c.env,
    sessionRow.crew_conversation_id,
    parsed.mentions,
    parsed.reply_to,
  );
  if (recip.error) {
    if (recip.error.status >= 400 && recip.error.status < 500) {
      return jsonError(c, 400, 'invalid_body', { message: recip.error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: recip.error.message });
  }

  const dbMessageKind = parsed.category === 'question' ? 'question' : 'status';
  const payload: Record<string, unknown> = {
    text: parsed.content,
    source: 'session_post_to_crew',
  };
  if (parsed.category) payload.category = parsed.category;

  const { data, error } = await svc.rpc('create_crew_announcement_from_runner_for_subject', {
    p_runner_host_id: sessionRow.runner_host_id,
    p_responsible_subject_id: sessionRow.responsible_subject_id,
    p_crew_session_id: sessionRow.id,
    p_recipient_session_ids: recip.sessionIds as unknown as Json,
    p_recipient_member_ids: recip.memberIds as unknown as Json,
    p_message_kind: dbMessageKind,
    p_summary: parsed.content,
    p_payload: payload as Json,
    p_board_visible: true,
  } as never);
  if (error) {
    const message = rpcMessage(error);
    if (/forbidden|lease/i.test(message)) return jsonError(c, 403, 'session_forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'session_not_found', { message });
    if (/invalid|required/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  // Also mirror into the crew group chat (spec §9: the chat IS the crew
  // conversation's `messages`). The announcement above is the board source of
  // truth; this row is what renders the post in the group stream as a session
  // card (role='log' → mapMessageToEntry senderKind='session', attributed via
  // log_payload.session_id). Best-effort: a failure must NOT fail the request
  // — the announcement already succeeded.
  // `reply_to` linkage rides in the mirror's log_payload.in_reply_to (no new
  // column) so future UI can thread the conversation.
  const mirrorMessageId = crypto.randomUUID();
  try {
    const { error: msgErr } = await svc.from('messages').insert({
      id: mirrorMessageId,
      client_message_id: crypto.randomUUID(),
      conversation_id: sessionRow.crew_conversation_id,
      role: 'log',
      log_kind: 'session_post',
      log_payload: {
        kind: 'session_post',
        session_id: sessionId,
        text: parsed.content,
        category: parsed.category ?? null,
        ...(recip.inReplyTo ? { in_reply_to: recip.inReplyTo } : {}),
      },
      content: parsed.content,
      status: 'done',
    } as never);
    if (msgErr) {
      console.warn('[session post-to-crew] messages mirror insert failed', msgErr.message);
    }
  } catch (e) {
    console.warn('[session post-to-crew] messages mirror insert threw', e);
  }

  // Directed mailbox fan-out for each @session / reply_to-of-a-session target
  // (Phase 2, parity with the human-sender path). Member recipients (a human
  // auto-@d via reply_to) get NO mailbox — humans read the group chat directly.
  // Best-effort: an enqueue failure must NOT fail the post (announcement +
  // mirror already landed).
  for (const targetSessionId of recip.sessionIds) {
    const { error: enqErr } = await untypedRpc(svc).rpc('enqueue_session_mailbox', {
      p_session_id: targetSessionId,
      p_message_kind: 'instruction',
      p_summary: parsed.content,
      p_payload: { source: recip.inReplyTo ? 'crew_reply' : 'crew_mention' },
      p_source_message_id: mirrorMessageId,
    });
    if (enqErr) {
      console.warn('[session post-to-crew] enqueue_session_mailbox failed', targetSessionId, enqErr.message);
    }
  }

  return c.json({ announcementId: data, category: parsed.category ?? null });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/sessions/:sessionId/request-permission
//
// T4.3 server-side reception for the spec v2 §10 `request_permission`
// agent tool. The runner translates the tool-call from Claude Code /
// Codex into this HTTP POST. Auth is device-grant only — the runner
// owns the session lease and is the authoritative source for
// "this session emitted this tool call".
//
// The tool itself does NOT pause the agent in this iteration: T4.5
// peer_device communication is what wires the round-trip back to the
// runner. For now the request lands as a crew_announcements card (via
// create_permission_request RPC) and the agent keeps going. The
// prompt-side note (request-permission-tool-result.md) tells the agent
// not to actually execute the underlying high-risk action until it sees
// a status flip to 'approved' in a later turn's whiteboard context.
// ────────────────────────────────────────────────────────────────────

sessionInboxRoutes.post('/:sessionId/request-permission', requireSubjectAuth(['crew:write']), async (c) => {
  const sessionId = c.req.param('sessionId');
  if (!isUuid(sessionId)) {
    return jsonError(c, 400, 'invalid_id', { message: 'sessionId must be a uuid' });
  }
  if (c.var.authKind !== 'device_grant') {
    return jsonError(c, 403, 'forbidden', {
      message: 'request-permission requires a device grant (runner-only path)',
    });
  }
  const deviceGrant = c.var.deviceGrant!;

  let parsed: z.infer<typeof SessionRequestPermissionBody>;
  try {
    parsed = SessionRequestPermissionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const svc = serviceClient(c.env);
  const { data: sessionRow, error: sessionErr } = await svc
    .from('crew_sessions')
    .select('id, responsible_subject_id, runner_host_id, status, crew_conversation_id')
    .eq('id', sessionId)
    .maybeSingle();
  if (sessionErr) return jsonError(c, 500, 'database_error', { detail: sessionErr.message });
  if (!sessionRow) return jsonError(c, 404, 'session_not_found');
  if (sessionRow.responsible_subject_id !== deviceGrant.subjectId) {
    return jsonError(c, 403, 'session_forbidden');
  }
  if (!sessionRow.runner_host_id) {
    return jsonError(c, 409, 'conflict', {
      message: 'session has no active runner host — cannot request on its behalf',
    });
  }

  const { data, error } = await untypedRpc(svc).rpc('create_permission_request', {
    p_session_id: sessionId,
    p_action: parsed.action,
    p_payload: parsed.details as unknown as Json,
    p_risk_level: parsed.risk_level ?? 'medium',
  });
  if (error) {
    const message = rpcMessage(error);
    if (/forbidden/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'session_not_found', { message });
    if (/invalid|required/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }
  return c.json({ permissionRequestId: data, status: 'pending' });
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
