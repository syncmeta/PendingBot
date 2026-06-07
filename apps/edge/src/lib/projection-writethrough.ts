// 投影写穿 —— T2 边缘读投影的喂养通道。
//
// 同一条 Supabase Database Webhook(routes/realtime-internal.ts)在扇出实时
// 增量(REALTIME_HUB)之外,顺手把行物化进读投影 DO:
//   - ConvProjectionDO(per conversation_id):消息尾 + roster + conv meta
//   - UserProjectionDO(per user_id):会话列表 + 未读
//
// 触发表 → DO 方法映射:
//   messages                  → Conv.ingestMessage / Conv.markDeleted
//   conversation_participants → Conv.ingestRoster + User.ingestConversation/removeConversation
//   conversations             → Conv.setMeta + 扇 roster 成员 User.ingestConversation
//   user_unread_counts        → User.ingestUnread
//
// 全部 fire-and-forget(调用方用 c.executionCtx.waitUntil 包),幂等(DO 内
// 按 id/conv_id upsert),失败只 log 不阻塞 webhook(投影是可重建派生,冷路径
// 回落 Supabase+RLS 兜底)。设计见
// docs/superpowers/plans/2026-06-07-edge-read-offload.md(§6/§7/§8/§9)。
import type { Env } from '../types';

/**
 * 进读投影的触发表(注意:与 realtime 扇出的 RealtimeTable 不同集 ——
 * `conversations` 喂投影但不扇出实时;`bot_lookbacks`/`crew_*`/`envelope_runs`
 * 扇出但不进投影)。
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

/** 给某 DO stub POST 一个 op JSON;失败只吞 + log(best-effort 写穿)。 */
async function rpc(
  stub: DurableObjectStub,
  origin: string,
  path: string,
  body: Record<string, unknown>,
): Promise<void> {
  try {
    await stub.fetch(`https://${origin}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (err) {
    console.error('[projection] write-through failed', origin, path, err);
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
      return projectConversation(env, row);
    case 'user_unread_counts':
      return projectUnread(env, row);
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
    return rpc(stub, 'conv-projection.do', '/mark-deleted', { id });
  }

  // §7.2:语音通话回顾行对用户 JWT 不可见 → 永不进投影。挡在喂养边界
  // (读投影无 metadata,读时无从复刻这条 RLS 过滤)。
  if (isVoiceCallSummary(row)) return;

  // 全字段交给 ingestMessage —— 2MB 行护栏在 DO 内统一兜(citations/metadata/
  // log_payload 可能大),writethrough 层不重复实现护栏。富列即 messages 表
  // 自有列(非关系数据),整套搬进投影(= iOS MessagesFetch.latest select 列)。
  return rpc(stub, 'conv-projection.do', '/ingest-message', {
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

  // 同步该用户的会话列表:加入 → 建最小列表行;退出 → 移出列表。
  const userS = userStub(env, participantId);
  if (rosterOp === 'remove') {
    return rpc(userS, 'user-projection.do', '/remove-conversation', { convId: conversationId });
  }
  return rpc(userS, 'user-projection.do', '/ingest-conversation', {
    row: {
      conv_id: conversationId,
      // 加入时未知 conv_type / title;conversations webhook 会随后补全。
      // 用占位 type,等会话行 webhook 覆盖元数据(unread 省略 → 保留)。
      type: 'unknown',
      updated_at: str(row, 'joined_at') ?? new Date().toISOString(),
    },
  });
}

// ── conversations → Conv.meta + 扇 roster 成员 User.list ─────────

async function projectConversation(env: Env, row: Record<string, unknown>): Promise<void> {
  const conversationId = str(row, 'id');
  if (!conversationId) return;
  const convType = str(row, 'conversation_type') ?? 'unknown';
  const ownerUserId = str(row, 'user_id');
  const title = str(row, 'title');
  const updatedAt = str(row, 'updated_at') ?? new Date().toISOString();
  // 标量会话列(ConversationFetch.list select 的标量列)。bot/peer embed
  // (bots!fkey 的 display_name/model_id…)不反范式化进投影 —— bot 改名要刷
  // 所有会话行,改由客户端本地缓存 hydration(见 UserConversationRow 文档)。
  const botId = str(row, 'bot_id');
  const feature = str(row, 'feature');
  const roundCount = int(row, 'round_count');

  const stub = convStub(env, conversationId);
  await rpc(stub, 'conv-projection.do', '/set-meta', {
    patch: { conv_type: convType, owner_user_id: ownerUserId },
  });

  // 标题/updated_at 是列表条目级元数据:从 conv DO 拿当前 roster,fan 到每个
  // 成员的 UserProjectionDO 更新列表行。owner 也并入(单 owner 会话 roster 可
  // 能为空,但 owner 仍需见到该会话)。
  const members = await fetchRoster(stub);
  if (ownerUserId) members.add(ownerUserId);
  await Promise.all(
    [...members].map((userId) =>
      rpc(userStub(env, userId), 'user-projection.do', '/ingest-conversation', {
        row: {
          conv_id: conversationId,
          type: convType,
          // owner_user_id(conversations.user_id)= 会话所属人,投影列也叫
          // user_id,对齐 ConversationFetch.list。
          user_id: ownerUserId,
          bot_id: botId,
          feature,
          round_count: roundCount,
          title,
          updated_at: updatedAt,
        },
      }),
    ),
  );
}

/** 从 ConvProjectionDO 取当前 roster(失败返回空集,best-effort)。 */
async function fetchRoster(stub: DurableObjectStub): Promise<Set<string>> {
  try {
    const res = await stub.fetch('https://conv-projection.do/roster', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    if (!res.ok) return new Set();
    const json = (await res.json()) as { roster?: string[] };
    return new Set(json.roster ?? []);
  } catch (err) {
    console.error('[projection] fetchRoster failed', err);
    return new Set();
  }
}

// ── user_unread_counts → User.unread ────────────────────────────

async function projectUnread(env: Env, row: Record<string, unknown>): Promise<void> {
  const userId = str(row, 'user_id');
  const conversationId = str(row, 'conversation_id');
  if (!userId || !conversationId) return;
  const count = Math.max(0, Math.trunc(Number(row.unread_count ?? 0)));
  // last_message_preview 缺省(undefined)→ 不动列表预览;有值(含 null)→ 覆盖。
  const preview = 'last_message_preview' in row ? str(row, 'last_message_preview') : undefined;
  return rpc(userStub(env, userId), 'user-projection.do', '/ingest-unread', {
    convId: conversationId,
    count,
    ...(preview === undefined ? {} : { preview }),
  });
}
