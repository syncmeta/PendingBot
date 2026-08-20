// 投影写穿 —— T2 边缘读投影的喂养通道。
//
// 两条入口:
//
// 1) **DB webhook**(routes/realtime-internal.ts)—— 有 `realtime_notify` 触发器
//    的表,同一条 webhook 在扇出实时增量之外顺手把行物化进投影 DO:
//      messages                  → Conv.ingestMessage / Conv.markDeleted
//      conversation_participants → Conv.ingestRoster + User.ingest/removeConversation
//
// 2) **边缘自推**(本文件导出的 syncConversationProjection /
//    patchConversationProjection / publishUnreadToProjection)—— 没有触发器的
//    会话级状态,由边缘自己在写完之后推进投影:
//      conversations       —— 从来没有过 realtime_notify 触发器
//      user_unread_counts  —— 触发器在 2026-05-29 被主动删掉(迁移
//                             20260529043410),理由写的是"改由边缘自己发",
//                             但边缘这半直到本次修复前从未接上。
//
//    后果就是「会话列表投影永远补不全」:新会话只拿到 participants 那一下的
//    占位行(标题空、bot_id 空、预览空、时间戳停在加入那一刻),而"随后补全"
//    的会话行通知永远不来。修法不是把触发器补回去(那是被主动去掉的成本),
//    而是兑现那条决策承诺的另一半 —— 边缘经手的会话级变更,写完顺手推投影。
//
// **投影里不再允许占位行。** 拿不到会话行就什么都不写并 loudly 报错:一个
// 永远等不到补全的占位行比没有这一行更糟 —— 它让读方以为数据已经有了。
//
// 全部 best-effort(调用方用 waitUntil 包),幂等(DO 内按 id/conv_id upsert),
// 失败不阻塞主流程,但**一定留下 [projection][write-through-failed] 日志**。
// 冷路径(读端点 miss)仍由 Supabase+RLS 兜底。设计见
// docs/superpowers/plans/2026-06-07-edge-read-offload.md(§6/§7/§8/§9)。
import type { Env } from '../types';
import type { ConversationPatch } from '../durable-objects/user-projection';
import { serviceClient } from './supabase';

/**
 * 进读投影的 webhook 表(注意:与 realtime 扇出的 RealtimeTable 不同集 ——
 * `conversations` 喂投影但不扇出实时;`bot_lookbacks`/`crew_*`/`envelope_runs`
 * 扇出但不进投影)。
 *
 * ⚠️ `conversations` / `user_unread_counts` 这两张表**线上并没有触发器**
 * (见文件头)。保留分支只是"万一将来又建了触发器也不会走错路";它们真正的
 * 喂养通道是本文件导出的边缘自推函数。
 */
export type ProjectionTable =
  | 'messages'
  | 'conversation_participants'
  | 'conversations'
  | 'user_unread_counts';

type WebhookOp = 'insert' | 'update' | 'delete';

/** webhook record 的弱类型读取助手(避免 any)。 */
function str(row: Record<string, unknown>, key: string): string | null {
  const v = row[key];
  return typeof v === 'string' ? v : null;
}

/**
 * 整数列读取(webhook JSON 数字 / 数字字符串 → number,缺省/非法 → null)。
 * round_count / message_seq 走这里。
 */
function int(row: Record<string, unknown>, key: string): number | null {
  const v = row[key];
  if (v == null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

/**
 * JSON 列原值透传(citations / metadata / log_payload):webhook 已把 jsonb 解成
 * JS 值,直接交给 DO(DO 内 JSON.stringify 落 *_json 文本列,并过 2MB 护栏)。
 * 缺省键 → null。
 */
function jsonCol(row: Record<string, unknown>, key: string): unknown {
  return key in row ? (row[key] ?? null) : null;
}

/**
 * §7.2 RLS 隐式过滤复刻:`metadata.source = 'voice_call_summary'` 的语音通话
 * 回顾行被 migration 20260520034417 的 SELECT policy 对用户 JWT 隐藏(只
 * service-role 的记忆管线读得到)。投影行不带 metadata,读端点无从在读时复刻
 * 这条过滤,所以必须在喂养边界把这类行挡在投影外 —— 与 status='deleted' 同理。
 * 冷路径(读端点 miss 回落 Supabase+RLS)本就自动滤掉,只有热投影需要这道闸。
 */
function isVoiceCallSummary(row: Record<string, unknown>): boolean {
  const meta = row.metadata;
  if (!meta || typeof meta !== 'object') return false;
  return (meta as Record<string, unknown>).source === 'voice_call_summary';
}

function convStub(env: Env, conversationId: string): DurableObjectStub {
  return env.CONV_PROJECTION.get(env.CONV_PROJECTION.idFromName(conversationId));
}

function userStub(env: Env, userId: string): DurableObjectStub {
  return env.USER_PROJECTION.get(env.USER_PROJECTION.idFromName(userId));
}

/**
 * 写穿失败的统一告警口。**这个 bug 能活两个多月,正是因为"通知没接上"从来
 * 没有任何人喊过一声** —— 所以每一条投影写失败都必须留下同一个可 grep /
 * 可告警的标记,而不是静默吞掉。
 */
export const PROJECTION_FAILURE_MARKER = '[projection][write-through-failed]';

function reportProjectionFailure(scope: string, detail: Record<string, unknown>): void {
  console.error(PROJECTION_FAILURE_MARKER, scope, JSON.stringify(detail));
}

/**
 * 给某 DO stub POST 一个 op JSON。返回解析后的响应体;失败(抛错或非 2xx)
 * 返回 null 并 loudly 报警 —— best-effort 指"不阻塞主流程",不指"无声无息"。
 */
async function rpc(
  stub: DurableObjectStub,
  origin: string,
  path: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown> | null> {
  try {
    const res = await stub.fetch(`https://${origin}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      reportProjectionFailure('do-rpc', { origin, path, status: res.status });
      return null;
    }
    return (await res.json().catch(() => ({}))) as Record<string, unknown>;
  } catch (err) {
    reportProjectionFailure('do-rpc', {
      origin,
      path,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

/**
 * 把一条 webhook 行物化进读投影。调用方负责 waitUntil 包裹(本函数 await
 * 内部 RPC,但抛错被各分支自己吞掉,不会拒掉 webhook)。返回 Promise 便于
 * waitUntil 跟踪生命周期。
 */
export async function projectWebhookRow(
  env: Env,
  table: ProjectionTable,
  op: WebhookOp,
  row: Record<string, unknown>,
): Promise<void> {
  switch (table) {
    case 'messages':
      return projectMessage(env, op, row);
    case 'conversation_participants':
      return projectParticipant(env, op, row);
    case 'conversations':
      return fanConversationRow(env, toConversationRow(row));
    case 'user_unread_counts':
      return projectUnreadRow(env, row);
  }
}

// ── messages → ConvProjectionDO ─────────────────────────────────

async function projectMessage(
  env: Env,
  op: WebhookOp,
  row: Record<string, unknown>,
): Promise<void> {
  const conversationId = str(row, 'conversation_id');
  const id = str(row, 'id');
  if (!conversationId || !id) return;
  const stub = convStub(env, conversationId);

  // 撤回/删除 → tombstone(§7.2:status='deleted' 是 RLS 隐式滤掉的行)。
  // 物理 DELETE 也按 tombstone 处理,让 delta-sync 能同步到删除。
  const status = str(row, 'status');
  if (op === 'delete' || status === 'deleted') {
    await rpc(stub, 'conv-projection.do', '/mark-deleted', { id });
    return;
  }

  // §7.2:语音通话回顾行对用户 JWT 不可见 → 永不进投影。挡在喂养边界
  // (读投影无 metadata,读时无从复刻这条 RLS 过滤)。
  if (isVoiceCallSummary(row)) return;

  // 全字段交给 ingestMessage —— 2MB 行护栏在 DO 内统一兜(citations/metadata/
  // log_payload 可能大),writethrough 层不重复实现护栏。富列即 messages 表
  // 自有列(非关系数据),整套搬进投影(= iOS MessagesFetch.latest select 列)。
  await rpc(stub, 'conv-projection.do', '/ingest-message', {
    row: {
      id,
      client_message_id: str(row, 'client_message_id'),
      created_at: str(row, 'created_at') ?? new Date().toISOString(),
      message_seq: int(row, 'message_seq'),
      role: str(row, 'role') ?? 'assistant',
      status: status ?? 'done',
      content: str(row, 'content') ?? '',
      log_kind: str(row, 'log_kind'),
      log_payload: jsonCol(row, 'log_payload'),
      bubble_group_id: str(row, 'bubble_group_id'),
      parent_message_id: str(row, 'parent_message_id'),
      model_slug: str(row, 'model_slug'),
      // messages.user_id 是人类发送者(bot 走 sender_bot_id),投影里叫
      // sender_user_id 以和 sender_bot_id 对称。
      sender_user_id: str(row, 'user_id'),
      sender_bot_id: str(row, 'sender_bot_id'),
      attachments: jsonCol(row, 'attachments'),
      citations: jsonCol(row, 'citations'),
      metadata: jsonCol(row, 'metadata'),
    },
  });
}

// ── conversation_participants → Conv.roster + User.list ─────────

async function projectParticipant(
  env: Env,
  op: WebhookOp,
  row: Record<string, unknown>,
): Promise<void> {
  const conversationId = str(row, 'conversation_id');
  if (!conversationId) return;
  // 只投影人类成员(participant_type='user');bot 成员不进 roster/列表。
  const participantType = str(row, 'participant_type');
  const participantId = str(row, 'participant_id');
  if (participantType !== 'user' || !participantId) return;

  const rosterOp = op === 'delete' ? 'remove' : 'add';
  await rpc(convStub(env, conversationId), 'conv-projection.do', '/ingest-roster', {
    op: rosterOp,
    userId: participantId,
  });

  if (rosterOp === 'remove') {
    await rpc(userStub(env, participantId), 'user-projection.do', '/remove-conversation', {
      convId: conversationId,
    });
    return;
  }

  // 加入 → 这个用户的列表里要出现这条会话。**这里不再写占位行**:webhook 只
  // 带 participants 的列,拿不到 conversation_type / bot_id / title,而"会话行
  // 通知随后补全"这件事线上根本不存在(conversations 没有触发器)。所以这里
  // 自己去补读一次会话行,把完整的一行落进去;读不到就什么都不写 + 报警。
  await syncConversationProjection(env, conversationId, {
    onlyUserIds: [participantId],
    reason: 'participant-join',
  });
}

// ── conversations → Conv.meta + 扇 roster 成员 User.list ─────────

/** 投影关心的会话标量列(= ConversationFetch.list select 的标量列)。 */
interface ConversationRow {
  id: string;
  conversation_type: string;
  user_id: string | null;
  bot_id: string | null;
  feature: string | null;
  round_count: number | null;
  title: string | null;
  updated_at: string;
}

/** webhook record / DB 行 → ConversationRow(弱类型收口)。 */
function toConversationRow(row: Record<string, unknown>): ConversationRow | null {
  const id = str(row, 'id');
  if (!id) return null;
  return {
    id,
    conversation_type: str(row, 'conversation_type') ?? '',
    user_id: str(row, 'user_id'),
    bot_id: str(row, 'bot_id'),
    feature: str(row, 'feature'),
    round_count: int(row, 'round_count'),
    title: str(row, 'title'),
    updated_at: str(row, 'updated_at') ?? new Date().toISOString(),
  };
}

/** service-role 补读一次会话行(绕 RLS;写穿点都在服务端)。 */
async function loadConversationRow(
  env: Env,
  conversationId: string,
): Promise<ConversationRow | null> {
  try {
    const { data, error } = await serviceClient(env)
      .from('conversations')
      .select('id, conversation_type, user_id, bot_id, feature, round_count, title, updated_at')
      .eq('id', conversationId)
      .maybeSingle();
    if (error) {
      reportProjectionFailure('load-conversation', {
        conversationId,
        error: error.message,
      });
      return null;
    }
    if (!data) return null;
    return toConversationRow(data as Record<string, unknown>);
  } catch (err) {
    reportProjectionFailure('load-conversation', {
      conversationId,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

/**
 * "谁的列表里该有这条会话" —— conv DO 的 roster + owner。owner 单独并进来:
 * 单 owner 会话的 roster 可能只有他自己,也可能(投影冷)为空。
 */
async function conversationAudience(
  env: Env,
  conversationId: string,
  ownerHint?: string | null,
): Promise<Set<string>> {
  const out = new Set<string>();
  if (ownerHint) out.add(ownerHint);
  const res = await rpc(convStub(env, conversationId), 'conv-projection.do', '/members', {});
  if (res) {
    const roster = Array.isArray(res.roster) ? (res.roster as unknown[]) : [];
    for (const u of roster) if (typeof u === 'string' && u) out.add(u);
    const owner = res.ownerUserId;
    if (typeof owner === 'string' && owner) out.add(owner);
  }
  return out;
}

/** 把一条完整会话行扇进 conv meta + 每个受众的会话列表。 */
async function fanConversationRow(
  env: Env,
  row: ConversationRow | null,
  opts?: { onlyUserIds?: string[] },
): Promise<void> {
  if (!row) return;
  const convType = row.conversation_type || 'unknown';
  await rpc(convStub(env, row.id), 'conv-projection.do', '/set-meta', {
    patch: { conv_type: convType, owner_user_id: row.user_id },
  });

  const audience = opts?.onlyUserIds
    ? new Set(opts.onlyUserIds)
    : await conversationAudience(env, row.id, row.user_id);
  if (audience.size === 0) {
    reportProjectionFailure('fan-conversation', {
      conversationId: row.id,
      reason: 'empty audience — nobody to project onto',
    });
    return;
  }

  // 标量会话列进列表行;bot/peer embed(display_name/头像)不反范式化进投影
  // —— bot 改名要刷所有会话行,改由客户端本地缓存 hydration(见
  // UserConversationRow 文档)。
  await Promise.all(
    [...audience].map((userId) =>
      rpc(userStub(env, userId), 'user-projection.do', '/ingest-conversation', {
        row: {
          conv_id: row.id,
          type: convType,
          user_id: row.user_id,
          bot_id: row.bot_id,
          feature: row.feature,
          round_count: row.round_count,
          title: row.title,
          updated_at: row.updated_at,
        },
      }),
    ),
  );
}

/**
 * **完整重同步**一条会话进投影:补读 conversations 行 → 扇给受众。
 *
 * 用于"投影里还没有这条会话"的场景(参与者加入、patch 落空)。读不到会话行
 * 就什么都不写(不造占位行)并报警;返回是否写成功,方便调用方决策。
 */
export async function syncConversationProjection(
  env: Env,
  conversationId: string,
  opts?: { onlyUserIds?: string[]; reason?: string },
): Promise<boolean> {
  const row = await loadConversationRow(env, conversationId);
  if (!row) {
    reportProjectionFailure('sync-conversation', {
      conversationId,
      reason: opts?.reason ?? 'unspecified',
      detail: 'conversations row unreadable — projection row intentionally NOT written',
    });
    return false;
  }
  await fanConversationRow(env, row, { onlyUserIds: opts?.onlyUserIds });
  return true;
}

/**
 * **局部推进**一条会话在投影里的列(起标题、轮次/时间戳推进的热路径)。
 * 不回读 conversations,直接把 patch 扇给受众。
 *
 * 任何一个受众的行不存在(或受众集为空)→ 自动回落一次完整
 * syncConversationProjection 把那一行补齐。这是"占位行不许再产生"的另一半:
 * 缺行时去补读,而不是凭 patch 造一行半成品。
 */
export async function patchConversationProjection(
  env: Env,
  conversationId: string,
  patch: ConversationPatch,
): Promise<void> {
  const audience = await conversationAudience(env, conversationId);
  if (audience.size === 0) {
    await syncConversationProjection(env, conversationId, { reason: 'patch-empty-audience' });
    return;
  }

  const missing: string[] = [];
  await Promise.all(
    [...audience].map(async (userId) => {
      const res = await rpc(
        userStub(env, userId),
        'user-projection.do',
        '/patch-conversation',
        { convId: conversationId, patch },
      );
      if (!res || res.found !== true) missing.push(userId);
    }),
  );

  if (missing.length > 0) {
    await syncConversationProjection(env, conversationId, {
      onlyUserIds: missing,
      reason: 'patch-row-missing',
    });
  }
}

// ── user_unread_counts → User.unread ────────────────────────────

/**
 * 一条 user_unread_counts 行 → 该用户列表行的 未读 / 预览 / 最后活跃时间。
 *
 * 线上这张表**没有触发器**(2026-05-29 撤掉),所以真正的调用方是
 * lib/unread-state.ts 的 notifyConversationUnreadState —— 边缘每次写完
 * 未读就顺手推一次(webhook 分支只是保留兼容)。
 *
 * 行不存在(投影里还没有这条会话)→ 回落一次完整 sync,而不是凭未读凭空
 * 造一行。
 */
export async function projectUnreadRow(
  env: Env,
  row: Record<string, unknown>,
): Promise<void> {
  const userId = str(row, 'user_id');
  const conversationId = str(row, 'conversation_id');
  if (!userId || !conversationId) return;
  const count = Math.max(0, Math.trunc(Number(row.unread_count ?? 0)));
  // last_message_preview 缺省(undefined)→ 不动列表预览;有值(含 null)→ 覆盖。
  const preview = 'last_message_preview' in row ? str(row, 'last_message_preview') : undefined;
  // 列表"最后活跃"跟着最新消息走 —— 会话行的 updated_at 通知早已不存在。
  const updatedAt = str(row, 'last_message_at');

  const res = await rpc(userStub(env, userId), 'user-projection.do', '/ingest-unread', {
    convId: conversationId,
    count,
    ...(preview === undefined ? {} : { preview }),
    ...(updatedAt ? { updatedAt } : {}),
  });
  if (res && res.found !== true) {
    await syncConversationProjection(env, conversationId, {
      onlyUserIds: [userId],
      reason: 'unread-row-missing',
    });
    // 补齐之后再把未读/预览盖上去(sync 只带会话标量列)。
    await rpc(userStub(env, userId), 'user-projection.do', '/ingest-unread', {
      convId: conversationId,
      count,
      ...(preview === undefined ? {} : { preview }),
      ...(updatedAt ? { updatedAt } : {}),
    });
  }
}
