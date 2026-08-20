// UserProjectionDO —— 每用户一个实例(keyed by user_id)。
//
// T2 边缘读投影(会话列表 + 未读)。Supabase 是真源 + 事件源 + 重建源;本 DO
// 是 per-user 的边缘会话列表/未读投影 + 单调 revision 计数器。
// 设计见 docs/superpowers/plans/2026-06-07-edge-read-offload.md(§4/§8/§9/§14)。
//
// 关键约定(实现决策 §14):
// - delta 不加 Postgres 列、无迁移:cursor = 本 DO 自有的单调 cur_rev。
//   每次摄入 ++cur_rev 并盖到那一行的 rev;客户端报 sinceRev 只回 rev>sinceRev。
// - epoch 在 DO 重建(冷启动 / 驱逐回填)时换新;cursor 的 epoch 不符 →
//   客户端 full 全量重取。
// - removeConversation 直接删行(列表投影无需 tombstone:整行消失即"移出列表")。
// - SQLite-backed,写法参照 wallet.ts(ctx.storage.sql.exec)。
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';

/**
 * 投影里一条会话列表行(对外 JSON 形状)。
 *
 * § 核心设计决策:会话列表只加**标量会话列**(bot_id/user_id/feature/
 * round_count 等 ConversationFetch.list select 的标量列),**绝不**反范式化
 * bot/peer 的 embed(头像/名字)—— 那会让 bot 改名要 fan-out 刷所有会话行。
 * bot/peer embed 由客户端用本地 bots/contacts 缓存 hydration(client 的事)。
 */
export interface UserConversationRow {
  conv_id: string;
  type: string;
  bot_id: string | null;
  user_id: string | null;
  feature: string | null;
  round_count: number | null;
  title: string | null;
  last_msg_preview: string | null;
  updated_at: string;
  unread: number;
  rev: number;
}

/** ingestConversation 的入参。标量会话列由 conversations webhook / 回填带入。 */
export interface IngestConversationInput {
  conv_id: string;
  type: string;
  bot_id?: string | null;
  user_id?: string | null;
  feature?: string | null;
  round_count?: number | null;
  title?: string | null;
  last_msg_preview?: string | null;
  updated_at: string;
  unread?: number;
}

/**
 * 历史遗留的占位类型。2026-08-19 之前,participants 写穿会落一行
 * `type:'unknown'` 的半成品,等一个永远不来的"随后补全"。新代码不再产生它,
 * 但**线上已有的 DO 里还躺着这种行** —— 所以把它当作"这一行不算数":任何
 * 局部更新落在它上面都报 found:false,让写穿层去补读真会话行把它换掉。
 */
const PLACEHOLDER_TYPE = 'unknown';

/**
 * patchConversation 的入参 —— 只盖给出的列,其余保留。`conv_id` 由参数带,
 * `type`/`updated_at` 可省(省则沿用行里现值)。
 */
export type ConversationPatch = Partial<Omit<IngestConversationInput, 'conv_id'>>;

/**
 * 列表排序键的单调合并:取两者中较晚的一个。
 *
 * 两个喂养源的时间戳格式不同(Postgres 的 `+00:00` vs 边缘 `toISOString()` 的
 * `Z`),所以按 Date.parse 的毫秒值比,不按字符串比。任一侧不可解析时以另一侧
 * 为准;都不可解析则取新值(至少别把行卡死在旧值上)。
 */
function maxTimestamp(current: string | null, incoming: string): string {
  if (!current) return incoming;
  const a = Date.parse(current);
  const b = Date.parse(incoming);
  if (!Number.isFinite(b)) return current;
  if (!Number.isFinite(a)) return incoming;
  return b >= a ? incoming : current;
}

/** meta 表已知键的 patch 形状。未列出的键也允许(自由 KV)。 */
export interface UserMetaPatch {
  backfilled?: boolean;
  [k: string]: string | number | boolean | null | undefined;
}

/** getList 返回。full=true 时调用方应丢弃本地、用 rows 全量替换。 */
export interface UserListResult {
  epoch: string;
  rev: number;
  rows: UserConversationRow[];
  /** sinceRev>cur_rev 或 epoch 不符 → 客户端 cursor 失效,应全量重取。 */
  full: boolean;
}

interface ConversationDbRow {
  conv_id: string;
  type: string;
  bot_id: string | null;
  user_id: string | null;
  feature: string | null;
  round_count: number | null;
  title: string | null;
  last_msg_preview: string | null;
  updated_at: string;
  unread: number;
  rev: number;
}

export class UserProjectionDO {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.state.blockConcurrencyWhile(async () => {
      this.state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS conversations (
          conv_id TEXT PRIMARY KEY,
          type TEXT NOT NULL,
          bot_id TEXT,
          user_id TEXT,
          feature TEXT,
          round_count INTEGER,
          title TEXT,
          last_msg_preview TEXT,
          updated_at TEXT NOT NULL,
          unread INTEGER NOT NULL DEFAULT 0,
          rev INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_conversations_rev ON conversations (rev);
        CREATE INDEX IF NOT EXISTS idx_conversations_updated ON conversations (updated_at);
        CREATE TABLE IF NOT EXISTS meta (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL
        );
      `);
      if (this.readMeta('epoch') == null) {
        this.writeMeta('epoch', crypto.randomUUID());
      }
      if (this.readMeta('cur_rev') == null) {
        this.writeMeta('cur_rev', '0');
      }
    });
  }

  // ── meta helpers ────────────────────────────────────────────────

  private readMeta(k: string): string | null {
    const row = this.state.storage.sql
      .exec<{ v: string }>('SELECT v FROM meta WHERE k = ?', k)
      .toArray()[0];
    return row ? row.v : null;
  }

  private writeMeta(k: string, v: string): void {
    this.state.storage.sql.exec(
      'INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v',
      k,
      v,
    );
  }

  private curRev(): number {
    return Number(this.readMeta('cur_rev') ?? '0');
  }

  /** 自增并持久化 cur_rev,返回新值。所有摄入路径都过这里。 */
  private bumpRev(): number {
    const next = this.curRev() + 1;
    this.writeMeta('cur_rev', String(next));
    return next;
  }

  private epoch(): string {
    return this.readMeta('epoch') ?? '';
  }

  // ── 摄入(webhook 写穿点调用)─────────────────────────────────

  /**
   * 幂等 upsert 一条会话列表行(按 conv_id)。每次写 ++cur_rev 并盖到该行 rev。
   *
   * 合并语义(**缺省 = 保留**,统一在 JS 里做,不再靠 SQL 的 COALESCE):
   * - 标量会话列(bot_id/user_id/feature/round_count/title)缺省 → 保留现值。
   *   写穿点可能只带一部分列(例如起标题只带 title),不该把别的列冲成 NULL。
   * - `last_msg_preview` 缺省 → **保留**现值。旧实现这里是无条件覆盖,导致
   *   任何一次 conversations 级写穿(不带预览)都会把列表预览清空。
   * - `unread` 缺省 → 保留现值;新行默认 0。
   * - `updated_at` 单调不回退(取 max)。列表排序键既被会话行(conversations.
   *   updated_at)喂,也被消息路径(last_message_at)喂,乱序到达不该让时间倒流。
   * - `type` 空串/缺省 → 保留现值(投影不再接受占位类型,见
   *   lib/projection-writethrough.ts 的 syncConversationProjection)。
   */
  ingestConversation(row: IngestConversationInput): void {
    const existing = this.readRow(row.conv_id);
    const rev = this.bumpRev();

    const type = row.type && row.type.length > 0 ? row.type : (existing?.type ?? 'unknown');
    const botId = row.bot_id ?? existing?.bot_id ?? null;
    const userId = row.user_id ?? existing?.user_id ?? null;
    const feature = row.feature ?? existing?.feature ?? null;
    const roundCount =
      row.round_count == null
        ? (existing?.round_count ?? null)
        : Math.trunc(row.round_count);
    const title = row.title ?? existing?.title ?? null;
    const preview =
      row.last_msg_preview === undefined
        ? (existing?.last_msg_preview ?? null)
        : row.last_msg_preview;
    const updatedAt = maxTimestamp(existing?.updated_at ?? null, row.updated_at);
    const unread =
      row.unread === undefined
        ? Number(existing?.unread ?? 0)
        : Math.max(0, Math.trunc(row.unread));

    this.state.storage.sql.exec(
      `INSERT INTO conversations
         (conv_id, type, bot_id, user_id, feature, round_count,
          title, last_msg_preview, updated_at, unread, rev)
       VALUES (?,?,?,?,?,?,?,?,?,?,?)
       ON CONFLICT(conv_id) DO UPDATE SET
         type = excluded.type,
         bot_id = excluded.bot_id,
         user_id = excluded.user_id,
         feature = excluded.feature,
         round_count = excluded.round_count,
         title = excluded.title,
         last_msg_preview = excluded.last_msg_preview,
         updated_at = excluded.updated_at,
         unread = excluded.unread,
         rev = excluded.rev`,
      row.conv_id,
      type,
      botId,
      userId,
      feature,
      roundCount,
      title,
      preview,
      updatedAt,
      unread,
      rev,
    );
  }

  /**
   * 局部更新一条**已存在**的列表行(边缘写穿的热路径:起标题、轮次/时间戳
   * 推进)。不带 DB 回读,只盖 patch 里给出的列。
   *
   * 返回 false = 该会话在本用户投影里不存在。调用方(writethrough)据此回落
   * 一次完整 sync(读 conversations 行重建),**绝不**凭空造占位行 —— 那正是
   * 「会话列表永远补不全」的病根。
   */
  patchConversation(convId: string, patch: ConversationPatch): boolean {
    const existing = this.readRow(convId);
    // 行不存在,或者行是历史遗留的占位半成品 → 都当"没有这一行"处理。
    if (!existing || existing.type === PLACEHOLDER_TYPE) return false;
    this.ingestConversation({
      ...patch,
      conv_id: convId,
      type: patch.type ?? existing.type,
      updated_at: patch.updated_at ?? existing.updated_at,
    });
    return true;
  }

  /** 单行读(内部合并用)。 */
  private readRow(convId: string): ConversationDbRow | null {
    const row = this.state.storage.sql
      .exec('SELECT * FROM conversations WHERE conv_id = ?', convId)
      .toArray()[0] as unknown as ConversationDbRow | undefined;
    return row ?? null;
  }

  /**
   * 更新某会话的未读数 + 预览 + 列表时间戳(红点路径)。
   *
   * 会话不存在则**返回 false**(列表里没有的会话不该凭未读凭空出现 —— 列表行
   * 由 ingestConversation 建立)。调用方据此回落一次完整 sync,而不是造占位行。
   *
   * `updatedAt`(= user_unread_counts.last_message_at)让"最后活跃时间"跟着新
   * 消息走 —— 会话行的 updated_at 通知已在 2026-05-29 被撤,这里是它的替身。
   */
  ingestUnread(
    convId: string,
    count: number,
    preview?: string | null,
    updatedAt?: string | null,
  ): boolean {
    const existing = this.readRow(convId);
    if (!existing || existing.type === PLACEHOLDER_TYPE) return false;
    const rev = this.bumpRev();
    const nextPreview = preview === undefined ? existing.last_msg_preview : preview;
    const nextUpdatedAt = updatedAt
      ? maxTimestamp(existing.updated_at, updatedAt)
      : existing.updated_at;
    this.state.storage.sql.exec(
      'UPDATE conversations SET unread = ?, last_msg_preview = ?, updated_at = ?, rev = ? WHERE conv_id = ?',
      Math.max(0, Math.trunc(count)),
      nextPreview,
      nextUpdatedAt,
      rev,
      convId,
    );
    return true;
  }

  /** 从列表移除一条会话(退群 / 删会话)。整行消失即"移出列表"。 */
  removeConversation(convId: string): void {
    this.state.storage.sql.exec('DELETE FROM conversations WHERE conv_id = ?', convId);
  }

  /** 合并写 meta(epoch / backfilled…)。 */
  setMeta(patch: UserMetaPatch): void {
    for (const [k, val] of Object.entries(patch)) {
      if (val === undefined) continue;
      const v = typeof val === 'boolean' ? (val ? '1' : '0') : val === null ? '' : String(val);
      this.writeMeta(k, v);
    }
  }

  // ── 读(读端点调用)─────────────────────────────────────────────

  /**
   * delta 会话列表。返回 rev>sinceRev 的行(按 updated_at 降序)。
   * sinceRev>cur_rev 或 epoch 不符 → full=true,回全量(无视 sinceRev)。
   */
  getList(opts?: { sinceRev?: number; epoch?: string }): UserListResult {
    const sinceRev = Math.max(0, Math.trunc(opts?.sinceRev ?? 0));
    const curRev = this.curRev();
    const epoch = this.epoch();
    const epochMismatch = opts?.epoch != null && opts.epoch !== epoch;
    const full = epochMismatch || sinceRev > curRev;
    const effectiveSince = full ? 0 : sinceRev;

    const rows = (
      this.state.storage.sql
        .exec(
          `SELECT * FROM conversations
           WHERE rev > ?
           ORDER BY updated_at DESC, conv_id DESC`,
          effectiveSince,
        )
        .toArray() as unknown as ConversationDbRow[]
    ).map((r) => this.toConversationRow(r));

    return { epoch, rev: curRev, rows, full };
  }

  /** meta 全集(k→v 字符串)。 */
  getMeta(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const r of this.state.storage.sql
      .exec<{ k: string; v: string }>('SELECT k, v FROM meta')
      .toArray()) {
      out[r.k] = r.v;
    }
    return out;
  }

  /**
   * 冷启动 / 驱逐回填:从 Supabase(service client,绕 RLS)一次重建会话列表 +
   * 未读,然后 backfilled=1、换新 epoch。懒触发:fetch 的 /list 在
   * backfilled!=1 时先 await 本方法再服务。
   *
   * 回填查询(`pendingbot` schema,对齐 iOS ConversationFetch.list 的列与过滤):
   *   FROM user_unread_counts WHERE user_id = <id>
   *     SELECT conversation_id, unread_count, last_message_preview,
   *            conv:conversations!inner(conversation_type, bot_id, user_id,
   *              feature, round_count, title, updated_at)
   *   —— user_unread_counts!inner 等价:只回该用户有未读行的会话(空会话过滤,
   *      与 iOS 的 `!inner` 一致);conversation_type='subagent' 的子会话排除
   *      (子代理对话从父级 tool trace 打开,不作顶层列表行)。
   *
   * 标量会话列(bot_id/user_id/feature/round_count/title)= ConversationFetch.list
   * select 的标量列,补齐供客户端 hydration;**不投影 bot/peer embed**(那是
   * 客户端用本地缓存做的事,见 UserConversationRow 文档)。updated_at 取会话的
   * updated_at(列表排序键);unread 取 unread_count;预览取 last_message_preview。
   *
   * 幂等性:rebuild 前清空 conversations 并把 cur_rev 归零;失败保持
   * backfilled!=1,下次读再试(best-effort,冷路径由 Supabase+RLS 兜底)。
   */
  async backfill(): Promise<void> {
    const userId = this.state.id.name;
    if (!userId) {
      throw new Error('UserProjectionDO.backfill: missing id name (must be idFromName)');
    }
    const supa = serviceClient(this.env);

    const { data, error } = await supa
      .from('user_unread_counts')
      .select(
        'conversation_id, unread_count, last_message_preview, conv:conversations!inner(conversation_type, bot_id, user_id, feature, round_count, title, updated_at)',
      )
      .eq('user_id', userId)
      .neq('conv.conversation_type', 'subagent');
    if (error) throw new Error(`UserProjectionDO.backfill: ${error.message}`);

    // 读成功后才动本地(失败上面已 throw,backfilled 保持未置位)。
    this.state.storage.sql.exec('DELETE FROM conversations');
    this.writeMeta('cur_rev', '0');

    for (const r of data ?? []) {
      // PostgREST 的 !inner 内嵌 to-one 关系返回单对象;防御性兼容数组形态。
      const conv = Array.isArray(r.conv) ? r.conv[0] : r.conv;
      if (!conv) continue;
      this.ingestConversation({
        conv_id: r.conversation_id,
        type: conv.conversation_type ?? 'unknown',
        bot_id: conv.bot_id,
        user_id: conv.user_id,
        feature: conv.feature,
        round_count: conv.round_count == null ? null : Math.trunc(Number(conv.round_count)),
        title: conv.title,
        last_msg_preview: r.last_message_preview,
        updated_at: conv.updated_at,
        unread: Math.max(0, Math.trunc(Number(r.unread_count ?? 0))),
      });
    }

    // 换 epoch(让重建前的 cursor 失效 → 客户端 full 重取)+ 标记已回填。
    this.writeMeta('epoch', crypto.randomUUID());
    this.setMeta({ backfilled: true });
  }

  /** backfilled!=1 时先回填一次(懒触发);已回填则直接返回。 */
  private async ensureBackfilled(): Promise<void> {
    if (this.readMeta('backfilled') === '1') return;
    await this.backfill();
  }

  private toConversationRow(r: ConversationDbRow): UserConversationRow {
    return {
      conv_id: r.conv_id,
      type: r.type,
      bot_id: r.bot_id,
      user_id: r.user_id,
      feature: r.feature,
      round_count: r.round_count == null ? null : Number(r.round_count),
      title: r.title,
      last_msg_preview: r.last_msg_preview,
      updated_at: r.updated_at,
      unread: Number(r.unread),
      rev: r.rev,
    };
  }

  // ── fetch RPC 入口 ──────────────────────────────────────────────
  // 仓库 DO 约定走 fetch(参照 wallet.ts / hub.ts)。写穿点
  // (routes/realtime-internal.ts)fire-and-forget 调写类 op;读 op(list/
  // meta)留给 E2 读端点。

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;

    switch (url.pathname) {
      case '/ingest-conversation': {
        this.ingestConversation(body.row as IngestConversationInput);
        return Response.json({ ok: true });
      }
      case '/ingest-unread': {
        const found = this.ingestUnread(
          String(body.convId ?? ''),
          Math.trunc(Number(body.count ?? 0)),
          body.preview === undefined ? undefined : (body.preview as string | null),
          body.updatedAt === undefined ? undefined : (body.updatedAt as string | null),
        );
        return Response.json({ ok: true, found });
      }
      case '/patch-conversation': {
        const found = this.patchConversation(
          String(body.convId ?? ''),
          (body.patch as ConversationPatch) ?? {},
        );
        return Response.json({ ok: true, found });
      }
      case '/remove-conversation': {
        this.removeConversation(String(body.convId ?? ''));
        return Response.json({ ok: true });
      }
      case '/set-meta': {
        this.setMeta((body.patch as UserMetaPatch) ?? {});
        return Response.json({ ok: true });
      }
      case '/list': {
        // 会话列表读:冷启动 / 被驱逐后先从 Supabase 重建一次。
        await this.ensureBackfilled();
        return Response.json(
          this.getList({
            sinceRev: typeof body.sinceRev === 'number' ? body.sinceRev : undefined,
            epoch: typeof body.epoch === 'string' ? body.epoch : undefined,
          }),
        );
      }
      case '/meta': {
        return Response.json({ meta: this.getMeta() });
      }
      default:
        return Response.json({ error: 'not found' }, { status: 404 });
    }
  }
}
