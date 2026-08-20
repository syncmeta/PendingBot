// T2 边缘读投影 —— 读端点(消息尾 + 会话列表/未读)。
//
//   GET /v1/conversations?since=<rev>&epoch=<e>          — 本用户会话列表 + 未读
//   GET /v1/messages/tail?conv=<id>&since=<rev>&epoch=<e>&limit=<n> — 某会话消息尾
//
// 设计见 docs/superpowers/plans/2026-06-07-edge-read-offload.md。本文件是读侧:
// 命中边缘投影 DO(③),miss/冷启动回落 Supabase+RLS(②)。投影写穿 + 冷回填在
// lib/projection-writethrough.ts + 两个投影 DO 里。
//
// ── 授权门(§7,最重)──────────────────────────────────────────────
// RLS 是数据层强制;数据搬到 CF 后这层没了,授权必须在 worker 显式重做。
//   - /conversations 读的是调用者自己的 USER_PROJECTION(idFromName(userId)),
//     键就是 JWT subject → 无跨用户风险,无需额外门。
//   - /messages/tail 必须 fail-closed 判成员:
//       · 单 owner 会话(user_bot/self/user_user/discuss/surf/portrait):
//         owner_user_id === userId ? pass : 403。
//       · 群会话:先查边缘 roster(CONV_PROJECTION.isMember,冷则回填后再判),
//         不确定回落 Supabase is_participant(带 user JWT,RLS 兜底)。
//       · 默认拒,绝不信客户端传来的 conversationId 本身(§7.3 不变量)。
// ── RLS 可见性复刻(§7.2)──────────────────────────────────────────
//   - deleted 消息只回 tombstone id,不回正文(投影 getTail 已 deleted=0 过滤 +
//     单独回 tombstone)。
//   - voice_call_summary(metadata.source)对用户 JWT 隐藏 → 已在喂养/回填边界
//     挡在投影外(lib/projection-writethrough.ts + conv-projection.ts backfill),
//     冷回落用用户 JWT 读 Supabase 时由 RLS 自动滤掉(此处冷查询额外显式排除以
//     与热投影一致)。
// ── 冷回落(§7.3)──────────────────────────────────────────────────
//   投影 miss / 空(理论上回填已兜底,但 best-effort 回填失败时仍可能空)→ 带
//   user JWT 读 Supabase,RLS 自动当第二道防线。

import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { getCachedConv, resolveConv, SINGLE_OWNER_TYPES } from '../lib/conv-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import { UUID_RE } from '../lib/ids';
import type { AppBindings, Env } from '../types';
import type { ConvTailResult, ConvMessageRow } from '../durable-objects/conv-projection';
import type { UserListResult } from '../durable-objects/user-projection';

// 两个独立 router(不同挂载前缀):
//   conversationListRoutes → GET /v1/conversations
//   messageTailRoutes      → GET /v1/messages/tail
// 都过 requireSession。
export const conversationListRoutes = new Hono<AppBindings>();
export const messageTailRoutes = new Hono<AppBindings>();

conversationListRoutes.use('*', requireSession());
messageTailRoutes.use('*', requireSession());

// 单 owner 会话类型(owner_user_id 即成员证明)从 conv-cache 单源导入,
// 避免两处 Set 漂移 —— RLS 对齐不变量的护栏见 tests/projection-rls-guard.test.ts。

/** /messages/tail 默认/封顶返回条数(对齐 conv-projection 的 DEFAULT_TAIL_LIMIT≈200)。 */
const DEFAULT_TAIL_LIMIT = 200;
const MAX_TAIL_LIMIT = 500;

/**
 * 给 CONV_PROJECTION DO 发一个 op JSON(RPC over fetch,参照 wallet/hub 约定 +
 * lib/projection-writethrough.ts 的写穿调用)。
 */
async function convRpc<T>(
  env: Env,
  conversationId: string,
  path: string,
  body: Record<string, unknown>,
): Promise<T> {
  const stub = env.CONV_PROJECTION.get(env.CONV_PROJECTION.idFromName(conversationId));
  const res = await stub.fetch(`https://conv-projection.do${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return (await res.json()) as T;
}

async function userRpc<T>(
  env: Env,
  userId: string,
  path: string,
  body: Record<string, unknown>,
): Promise<T> {
  const stub = env.USER_PROJECTION.get(env.USER_PROJECTION.idFromName(userId));
  const res = await stub.fetch(`https://user-projection.do${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return (await res.json()) as T;
}

/** ?since= → 非负整数 rev cursor;非法/缺省 = 0(全量起点)。 */
function parseSince(raw: string | undefined): number | undefined {
  if (raw == null || raw === '') return undefined;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return undefined;
  return Math.trunc(n);
}

// ── GET /v1/conversations ──────────────────────────────────────────
// 本用户会话列表 + 未读。读自己的 USER_PROJECTION,无跨用户授权面。
// delta:?since=<rev> 只回 rev>since 的行;?epoch 不符 → DO 回 full=true 全量。
conversationListRoutes.get('/', async (c) => {
  const userId = c.var.userId!;
  const sinceRev = parseSince(c.req.query('since'));
  const epoch = c.req.query('epoch');

  let result: UserListResult;
  try {
    result = await userRpc<UserListResult>(c.env, userId, '/list', {
      ...(sinceRev !== undefined ? { sinceRev } : {}),
      ...(epoch ? { epoch } : {}),
    });
  } catch (err) {
    return jsonError(c, 500, 'internal_error', {
      detail: (err as { message?: string }).message ?? 'user-projection list failed',
    });
  }

  return c.json(result);
});

// ── GET /v1/messages/tail ──────────────────────────────────────────
// 某会话消息尾。授权门 fail-closed;命中投影回 delta,冷 miss 回落 Supabase+RLS。
messageTailRoutes.get('/tail', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const conversationId = c.req.query('conv');
  if (!conversationId || !UUID_RE.test(conversationId)) {
    return jsonError(c, 400, 'invalid_query', { message: 'bad or missing conv id' });
  }
  const sinceRev = parseSince(c.req.query('since'));
  const epoch = c.req.query('epoch');
  const limitRaw = Number(c.req.query('limit'));
  const limit = Number.isFinite(limitRaw)
    ? Math.min(MAX_TAIL_LIMIT, Math.max(1, Math.trunc(limitRaw)))
    : DEFAULT_TAIL_LIMIT;

  const supaUser = userClient(c.env, userJwt);

  // ── 授权门(§7.1 + §7.3 fail-closed)─────────────────────────────
  // 先看 KV 缓存的 conv 类型(热路径,免 Supabase)。冷/群 → 走 resolveConv
  // (单 owner 本地判、群 RLS 判)+ 群再叠一层边缘 roster 快路径。
  const cachedConv = await getCachedConv(c.env, conversationId);

  let authorized = false;
  if (cachedConv && SINGLE_OWNER_TYPES.has(cachedConv.conversation_type)) {
    // 单 owner 热路径:owner_user_id === userId 即成员;不符 → 落 resolveConv
    // 复核(KV 可能在 user_id 写入前被别的路径预热成了 null)。
    if (cachedConv.user_id === userId) {
      authorized = true;
    }
  } else if (cachedConv) {
    // 群(KV 已知类型)热路径:先查边缘 roster(冷则 DO 内自动回填后再判)。
    try {
      const r = await convRpc<{ member: boolean }>(c.env, conversationId, '/is-member', {
        userId,
      });
      if (r.member) authorized = true;
    } catch {
      // 边缘判定失败 → 不放行,落 resolveConv 兜底。
    }
  }

  // 仍未放行(单 owner KV 不符 / 群 roster 未命中 / KV 冷)→ resolveConv:
  // 单 owner 本地比对、群带 user JWT 读 Supabase(RLS 才是权威成员判定)。
  // resolveConv 返回 null = 不存在或调用者无权 → fail-closed 403。
  if (!authorized) {
    let conv: { conversation_type: string; user_id: string | null } | null;
    try {
      conv = (await resolveConv(c.env, supaUser, conversationId, userId, (p) =>
        safeWaitUntil(c, p),
      )) as { conversation_type: string; user_id: string | null } | null;
    } catch (err) {
      return jsonError(c, 500, 'database_error', {
        detail: (err as { message?: string }).message ?? 'resolveConv failed',
      });
    }
    if (!conv) {
      // 不存在 vs 无权不区分(不泄露存在性,与 RLS 同语义)。
      return jsonError(c, 403, 'forbidden', { message: '无权访问该会话' });
    }
    // resolveConv 已把成员判定做完(单 owner 比对 user_id;群走 RLS 读,
    // 命中即成员)。能拿到非空 conv 即代表 RLS 放行 → authorized。
    authorized = true;
  }

  // ── 命中投影读消息尾(§8 delta)──────────────────────────────────
  // DO /tail 内部在冷启动/被驱逐后会先从 Supabase 回填一次再服务。
  let tail: ConvTailResult;
  try {
    tail = await convRpc<ConvTailResult>(c.env, conversationId, '/tail', {
      ...(sinceRev !== undefined ? { sinceRev } : {}),
      ...(epoch ? { epoch } : {}),
      limit,
    });
  } catch (err) {
    // 投影 RPC 失败 → 冷回落 Supabase+RLS(§7.3 第二道防线)。
    return tailFromSupabase(c, supaUser, conversationId, limit, err);
  }

  // 投影空(回填 best-effort 失败时可能发生)且这是一次全量请求 → 回落
  // Supabase+RLS 兜底,避免给客户端一个假的"空会话"。增量请求(sinceRev>0)
  // 空 rows 是正常的"无新变更",不回落。
  const isFullFetch = (sinceRev ?? 0) === 0 || tail.full;
  if (isFullFetch && tail.rows.length === 0 && tail.tombstones.length === 0) {
    return tailFromSupabase(c, supaUser, conversationId, limit);
  }

  return c.json(tail);
});

/**
 * 冷回落:带 user JWT 读 Supabase 的消息尾,RLS 自动当第二道防线(§7.3)。
 * 形状与投影 getTail 对齐(ConvTailResult),但 epoch=''、rev=0、full=true ——
 * 没有 DO 的 revision 上下文,客户端按 full 全量替换处理。
 * §7.2:排除 deleted(只回活行,tombstone=[])+ voice_call_summary。
 */
async function tailFromSupabase(
  c: Parameters<typeof jsonError>[0],
  supaUser: ReturnType<typeof userClient>,
  conversationId: string,
  limit: number,
  priorErr?: unknown,
): Promise<Response> {
  const { data, error } = await supaUser
    .from('messages')
    .select(
      'id, client_message_id, created_at, message_seq, role, status, content, log_kind, log_payload, bubble_group_id, parent_message_id, model_slug, user_id, sender_bot_id, attachments, citations, metadata',
    )
    .eq('conversation_id', conversationId)
    .neq('status', 'deleted')
    .or('metadata->>source.is.null,metadata->>source.neq.voice_call_summary')
    .order('message_seq', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    return jsonError(c, 500, 'database_error', {
      detail:
        (priorErr as { message?: string } | undefined)?.message ?? error.message,
    });
  }

  // DESC 取尾后翻回时间升序(UI 自上而下),与投影 getTail 同序。
  // 列与热投影 ConvMessageRow 对齐(MessagesFetch.latest 的全部消息自有列);
  // 冷回落不走 DO 的 2MB 护栏,直接回 Supabase 原值(冷路径单次读,可接受)。
  const rows: ConvMessageRow[] = (data ?? [])
    .map(
      (m): ConvMessageRow => ({
        id: m.id,
        client_message_id: m.client_message_id,
        created_at: m.created_at,
        message_seq: m.message_seq,
        role: m.role,
        status: m.status,
        content: m.content ?? '',
        log_kind: m.log_kind,
        log_payload: m.log_payload ?? null,
        bubble_group_id: m.bubble_group_id,
        parent_message_id: m.parent_message_id,
        model_slug: m.model_slug,
        // messages.user_id 是人类发送者(与投影写穿映射一致)。
        sender_user_id: m.user_id,
        sender_bot_id: m.sender_bot_id,
        attachments: m.attachments ?? null,
        citations: m.citations ?? null,
        metadata: m.metadata ?? null,
        rev: 0,
      }),
    )
    .reverse();

  const result: ConvTailResult = {
    epoch: '',
    rev: 0,
    rows,
    tombstones: [],
    full: true,
  };
  return c.json(result);
}
