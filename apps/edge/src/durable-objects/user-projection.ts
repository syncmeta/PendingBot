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

/** 投影里一条会话列表行(对外 JSON 形状)。 */
export interface UserConversationRow {
  conv_id: string;
  type: string;
  title: string | null;
  last_msg_preview: string | null;
  updated_at: string;
  unread: number;
  rev: number;
}

/** ingestConversation 的入参。 */
export interface IngestConversationInput {
  conv_id: string;
  type: string;
  title?: string | null;
  last_msg_preview?: string | null;
  updated_at: string;
  unread?: number;
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
   * unread 未传时保留原值(只更新元数据/预览的场景);新行默认 0。
   */
  ingestConversation(row: IngestConversationInput): void {
    const rev = this.bumpRev();
    if (row.unread === undefined) {
      // 不带 unread:upsert 时保留已存在行的 unread,新行用 0。
      this.state.storage.sql.exec(
        `INSERT INTO conversations
           (conv_id, type, title, last_msg_preview, updated_at, unread, rev)
         VALUES (?,?,?,?,?,0,?)
         ON CONFLICT(conv_id) DO UPDATE SET
           type = excluded.type,
           title = excluded.title,
           last_msg_preview = excluded.last_msg_preview,
           updated_at = excluded.updated_at,
           rev = excluded.rev`,
        row.conv_id,
        row.type,
        row.title ?? null,
        row.last_msg_preview ?? null,
        row.updated_at,
        rev,
      );
    } else {
      this.state.storage.sql.exec(
        `INSERT INTO conversations
           (conv_id, type, title, last_msg_preview, updated_at, unread, rev)
         VALUES (?,?,?,?,?,?,?)
         ON CONFLICT(conv_id) DO UPDATE SET
           type = excluded.type,
           title = excluded.title,
           last_msg_preview = excluded.last_msg_preview,
           updated_at = excluded.updated_at,
           unread = excluded.unread,
           rev = excluded.rev`,
        row.conv_id,
        row.type,
        row.title ?? null,
        row.last_msg_preview ?? null,
        row.updated_at,
        Math.max(0, Math.trunc(row.unread)),
        rev,
      );
    }
  }

  /**
   * 更新某会话的未读数 + 预览(红点路径)。会话不存在则忽略(列表里没有的
   * 会话不该凭未读凭空出现 —— 列表行由 ingestConversation 建立)。
   */
  ingestUnread(convId: string, count: number, preview?: string | null): void {
    const exists = this.state.storage.sql
      .exec<{ c: number }>('SELECT COUNT(*) AS c FROM conversations WHERE conv_id = ?', convId)
      .one();
    if (Number(exists.c) === 0) return;
    const rev = this.bumpRev();
    if (preview === undefined) {
      this.state.storage.sql.exec(
        'UPDATE conversations SET unread = ?, rev = ? WHERE conv_id = ?',
        Math.max(0, Math.trunc(count)),
        rev,
        convId,
      );
    } else {
      this.state.storage.sql.exec(
        'UPDATE conversations SET unread = ?, last_msg_preview = ?, rev = ? WHERE conv_id = ?',
        Math.max(0, Math.trunc(count)),
        preview,
        rev,
        convId,
      );
    }
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
   *            conv:conversations!inner(conversation_type, title, updated_at)
   *   —— user_unread_counts!inner 等价:只回该用户有未读行的会话(空会话过滤,
   *      与 iOS 的 `!inner` 一致);conversation_type='subagent' 的子会话排除
   *      (子代理对话从父级 tool trace 打开,不作顶层列表行)。
   *
   * updated_at 取会话的 updated_at(列表排序键,与 webhook 写穿一致);unread
   * 取 unread_count;预览取 last_message_preview。
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
        'conversation_id, unread_count, last_message_preview, conv:conversations!inner(conversation_type, title, updated_at)',
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
        this.ingestUnread(
          String(body.convId ?? ''),
          Math.trunc(Number(body.count ?? 0)),
          body.preview === undefined ? undefined : (body.preview as string | null),
        );
        return Response.json({ ok: true });
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
