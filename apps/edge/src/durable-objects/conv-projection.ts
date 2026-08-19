// ConvProjectionDO —— 每会话一个实例(keyed by conversation_id)。
//
// T2 边缘读投影(消息尾)。Supabase 是真源 + 事件源 + 重建源;本 DO 是
// per-conv 的边缘消息尾投影 + roster(授权门用)+ 单调 revision 计数器。
// 设计见 docs/superpowers/plans/2026-06-07-edge-read-offload.md(§6/§7/§8/§9/§14)。
//
// 关键约定(实现决策 §14):
// - delta 不加 Postgres 列、无迁移:cursor = 本 DO 自有的单调 cur_rev。
//   每次摄入(含 tombstone)++cur_rev 并盖到那一行的 rev,客户端报 sinceRev
//   只回 rev>sinceRev 的变更。
// - epoch 在 DO 重建(冷启动 / 驱逐回填)时换新;cursor 的 epoch 不符 →
//   客户端 full 全量重取。
// - 留存 N_keep≈1000 条;深翻历史走 Supabase(②),不靠 DO。
// - SQLite-backed,写法参照 wallet.ts(ctx.storage.sql.exec)。
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';

/** DO 留存的消息条数上限(按 created_at,id 排序,删最旧)。导出供测试断言 trim 边界。 */
export const N_KEEP = 1000;
/** getTail 默认返回条数;对齐现状 MessagesFetch.latest()(~200)。 */
const DEFAULT_TAIL_LIMIT = 200;

/**
 * 2MB 行护栏(§6 硬约束):DO SQLite 单行上限 2MB。富列(尤其 metadata /
 * log_payload JSON,可能挟带巨大 tool-trace)逼近上限时,写入前把最重的 JSON
 * 字段替换成截断标记,让客户端按需回 Supabase 懒取该条。阈值压到 ~1.5MB 留
 * 出其它列 + SQLite 行开销的余量。
 */
const ROW_SIZE_LIMIT_BYTES = 1_500_000;
/** 富列被裁掉时落的标记值(客户端识别 → 回 Supabase 懒取该条整行)。 */
export const TRUNCATED_MARKER = { __truncated: true } as const;

const TEXT_ENCODER = new TextEncoder();
/** UTF-8 字节长度(行大小估算用,JSON 含多字节字符时比 .length 准)。 */
function utf8Bytes(s: string): number {
  return TEXT_ENCODER.encode(s).length;
}

/** 投影里一条消息行(对外 JSON 形状,= MessagesFetch.latest 的全部消息自有列)。 */
export interface ConvMessageRow {
  id: string;
  client_message_id: string | null;
  created_at: string;
  message_seq: number | null;
  role: string;
  status: string;
  content: string;
  log_kind: string | null;
  /** 解析后的 log_payload JSON;被 2MB 护栏裁掉时为 { __truncated:true }。 */
  log_payload: unknown;
  bubble_group_id: string | null;
  parent_message_id: string | null;
  model_slug: string | null;
  sender_user_id: string | null;
  sender_bot_id: string | null;
  /** 解析后的 attachments JSON({ ids:[...] })。 */
  attachments: unknown;
  /** 解析后的 citations JSON 数组;被 2MB 护栏裁掉时为 { __truncated:true }。 */
  citations: unknown;
  /** 解析后的 metadata JSON;被 2MB 护栏裁掉时为 { __truncated:true }。 */
  metadata: unknown;
  rev: number;
}

/**
 * ingestMessage 的入参(= MessagesFetch.latest select 的全部消息自有列)。
 * JSON 列(attachments/citations/metadata/log_payload)传未序列化的原值,
 * DO 内 JSON.stringify 落进 *_json 文本列。
 */
export interface IngestMessageInput {
  id: string;
  client_message_id?: string | null;
  created_at: string;
  message_seq?: number | null;
  role: string;
  status: string;
  content: string;
  log_kind?: string | null;
  bubble_group_id?: string | null;
  parent_message_id?: string | null;
  model_slug?: string | null;
  sender_user_id?: string | null;
  sender_bot_id?: string | null;
  /** 结构化 attachments(会 JSON.stringify 存进 attachments_json)。 */
  attachments?: unknown;
  /** web-search 引用数组(会 JSON.stringify 存进 citations_json)。 */
  citations?: unknown;
  /** 消息 metadata JSON(可能含大 tool-trace,过 2MB 护栏)。 */
  metadata?: unknown;
  /** log 行 payload JSON(recall / crew_proposal 等,过 2MB 护栏)。 */
  log_payload?: unknown;
}

/** meta 表已知键的 patch 形状。未列出的键也允许(自由 KV)。 */
export interface ConvMetaPatch {
  conv_type?: string;
  owner_user_id?: string | null;
  backfilled?: boolean;
  [k: string]: string | number | boolean | null | undefined;
}

/** getTail 返回。full=true 时调用方应丢弃本地、用 rows 全量替换。 */
export interface ConvTailResult {
  epoch: string;
  rev: number;
  rows: ConvMessageRow[];
  tombstones: string[];
  /** sinceRev>cur_rev 或 epoch 不符 → 客户端 cursor 失效,应全量重取。 */
  full: boolean;
}

interface MessageDbRow {
  id: string;
  client_message_id: string | null;
  created_at: string;
  message_seq: number | null;
  role: string;
  status: string;
  content: string;
  log_kind: string | null;
  log_payload_json: string | null;
  bubble_group_id: string | null;
  parent_message_id: string | null;
  model_slug: string | null;
  sender_user_id: string | null;
  sender_bot_id: string | null;
  attachments_json: string | null;
  citations_json: string | null;
  metadata_json: string | null;
  deleted: number;
  rev: number;
}

export class ConvProjectionDO {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.state.blockConcurrencyWhile(async () => {
      this.state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS messages (
          id TEXT PRIMARY KEY,
          client_message_id TEXT,
          created_at TEXT NOT NULL,
          message_seq INTEGER,
          role TEXT NOT NULL,
          status TEXT NOT NULL,
          content TEXT NOT NULL,
          log_kind TEXT,
          log_payload_json TEXT,
          bubble_group_id TEXT,
          parent_message_id TEXT,
          model_slug TEXT,
          sender_user_id TEXT,
          sender_bot_id TEXT,
          attachments_json TEXT,
          citations_json TEXT,
          metadata_json TEXT,
          deleted INTEGER NOT NULL DEFAULT 0,
          rev INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_rev ON messages (rev);
        CREATE INDEX IF NOT EXISTS idx_messages_order ON messages (created_at, id);
        CREATE TABLE IF NOT EXISTS roster (
          user_id TEXT PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS meta (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL
        );
      `);
      // epoch 在对象首次构建时落一次;之后只在显式 resetEpoch(回填)时换。
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

  /** 自增并持久化 cur_rev,返回新值。所有摄入路径(含 tombstone)都过这里。 */
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
   * 幂等 upsert 一条消息(按 id)。每次写 ++cur_rev 并盖到该行 rev,使
   * delta-sync 能用 rev 追增量。写后 trim 到最近 N_KEEP 条(按 created_at,id)。
   *
   * 2MB 行护栏(§6):富列(content + 4 个 JSON 列)合起来可能逼近 DO 单行 2MB
   * 上限。写入前估算总字节,超阈值就把最重的 JSON 列(metadata / log_payload /
   * citations 里最大的那个,按字节降序)逐个替换成 TRUNCATED_MARKER,直到落到
   * 阈值下;客户端见到 {__truncated:true} 即回 Supabase 懒取该条整行。content
   * 是渲染主体不裁(超大 content 极罕见,真碰到也只能整条懒取,留给后续)。
   */
  ingestMessage(row: IngestMessageInput): void {
    const rev = this.bumpRev();
    const guarded = this.applyRowSizeGuard(row);
    this.state.storage.sql.exec(
      `INSERT INTO messages
         (id, client_message_id, created_at, message_seq, role, status, content,
          log_kind, log_payload_json, bubble_group_id, parent_message_id,
          model_slug, sender_user_id, sender_bot_id, attachments_json,
          citations_json, metadata_json, deleted, rev)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)
       ON CONFLICT(id) DO UPDATE SET
         client_message_id = excluded.client_message_id,
         created_at = excluded.created_at,
         message_seq = excluded.message_seq,
         role = excluded.role,
         status = excluded.status,
         content = excluded.content,
         log_kind = excluded.log_kind,
         log_payload_json = excluded.log_payload_json,
         bubble_group_id = excluded.bubble_group_id,
         parent_message_id = excluded.parent_message_id,
         model_slug = excluded.model_slug,
         sender_user_id = excluded.sender_user_id,
         sender_bot_id = excluded.sender_bot_id,
         attachments_json = excluded.attachments_json,
         citations_json = excluded.citations_json,
         metadata_json = excluded.metadata_json,
         deleted = 0,
         rev = excluded.rev`,
      row.id,
      row.client_message_id ?? null,
      row.created_at,
      row.message_seq ?? null,
      row.role,
      row.status,
      row.content,
      row.log_kind ?? null,
      guarded.logPayloadJson,
      row.bubble_group_id ?? null,
      row.parent_message_id ?? null,
      row.model_slug ?? null,
      row.sender_user_id ?? null,
      row.sender_bot_id ?? null,
      guarded.attachmentsJson,
      guarded.citationsJson,
      guarded.metadataJson,
      rev,
    );
    this.trim();
  }

  /**
   * 2MB 行护栏:序列化 4 个 JSON 列,若 content + 各 JSON 列总字节超
   * ROW_SIZE_LIMIT_BYTES,按字节降序把可裁字段(metadata / log_payload /
   * citations,不含 attachments —— ids 数组本就小、客户端解析附件元数据要它)
   * 逐个替换成 TRUNCATED_MARKER,直到落到阈值下。返回各列最终的 JSON 文本。
   */
  private applyRowSizeGuard(row: IngestMessageInput): {
    attachmentsJson: string | null;
    citationsJson: string | null;
    metadataJson: string | null;
    logPayloadJson: string | null;
  } {
    const truncated = JSON.stringify(TRUNCATED_MARKER);
    const ser = (v: unknown): string | null => (v === undefined ? null : JSON.stringify(v));

    const attachmentsJson = ser(row.attachments);
    let citationsJson = ser(row.citations);
    let metadataJson = ser(row.metadata);
    let logPayloadJson = ser(row.log_payload);

    const byteLen = (s: string | null): number => (s == null ? 0 : utf8Bytes(s));
    const total = (): number =>
      utf8Bytes(row.content) +
      byteLen(attachmentsJson) +
      byteLen(citationsJson) +
      byteLen(metadataJson) +
      byteLen(logPayloadJson);

    if (total() <= ROW_SIZE_LIMIT_BYTES) {
      return { attachmentsJson, citationsJson, metadataJson, logPayloadJson };
    }

    // 可裁字段按当前字节降序,先裁最重的,直到落到阈值下。
    const slots: Array<{ get: () => string | null; truncate: () => void }> = [
      { get: () => metadataJson, truncate: () => (metadataJson = truncated) },
      { get: () => logPayloadJson, truncate: () => (logPayloadJson = truncated) },
      { get: () => citationsJson, truncate: () => (citationsJson = truncated) },
    ].sort((a, b) => byteLen(b.get()) - byteLen(a.get()));
    for (const slot of slots) {
      if (total() <= ROW_SIZE_LIMIT_BYTES) break;
      if (slot.get() == null || slot.get() === truncated) continue;
      slot.truncate();
    }
    return { attachmentsJson, citationsJson, metadataJson, logPayloadJson };
  }

  /** 撤回/删除 → tombstone:deleted=1, rev=++cur_rev(delta 能同步到删除)。 */
  markDeleted(id: string): void {
    const rev = this.bumpRev();
    this.state.storage.sql.exec(
      'UPDATE messages SET deleted = 1, rev = ? WHERE id = ?',
      rev,
      id,
    );
  }

  /** roster 维护(授权门数据源):op='add' 落行,op='remove' 删行。 */
  ingestRoster(op: 'add' | 'remove', userId: string): void {
    if (op === 'add') {
      this.state.storage.sql.exec(
        'INSERT INTO roster (user_id) VALUES (?) ON CONFLICT(user_id) DO NOTHING',
        userId,
      );
    } else {
      this.state.storage.sql.exec('DELETE FROM roster WHERE user_id = ?', userId);
    }
  }

  /** 合并写 meta(conv_type / owner_user_id / backfilled / epoch…)。 */
  setMeta(patch: ConvMetaPatch): void {
    for (const [k, val] of Object.entries(patch)) {
      if (val === undefined) continue;
      const v = typeof val === 'boolean' ? (val ? '1' : '0') : val === null ? '' : String(val);
      this.writeMeta(k, v);
    }
  }

  /** 留存裁剪:超过 N_KEEP 条时删最旧的(按 created_at,id 升序)。 */
  private trim(): void {
    const countRow = this.state.storage.sql
      .exec<{ c: number }>('SELECT COUNT(*) AS c FROM messages')
      .one();
    const excess = Number(countRow.c) - N_KEEP;
    if (excess <= 0) return;
    this.state.storage.sql.exec(
      `DELETE FROM messages WHERE id IN (
         SELECT id FROM messages ORDER BY created_at ASC, id ASC LIMIT ?
       )`,
      excess,
    );
  }

  // ── 读(读端点调用)─────────────────────────────────────────────

  /**
   * delta 消息尾。返回 rev>sinceRev 的非删除行(最近 limit 条)+ 同窗口的
   * tombstone id。sinceRev>cur_rev → cursor 来自未来(异常),full=true。
   * 传入 epoch 与本 DO 不符 → cursor 跨重建失效,full=true(调用方全量重取)。
   */
  getTail(opts?: { sinceRev?: number; limit?: number; epoch?: string }): ConvTailResult {
    const sinceRev = Math.max(0, Math.trunc(opts?.sinceRev ?? 0));
    const limit = Math.max(1, Math.trunc(opts?.limit ?? DEFAULT_TAIL_LIMIT));
    const curRev = this.curRev();
    const epoch = this.epoch();
    const epochMismatch = opts?.epoch != null && opts.epoch !== epoch;
    const full = epochMismatch || sinceRev > curRev;
    // full 时无视 sinceRev,回最近 limit 条(全量重取);否则只回增量。
    const effectiveSince = full ? 0 : sinceRev;

    const rows = (
      this.state.storage.sql
        .exec(
          `SELECT * FROM messages
           WHERE deleted = 0 AND rev > ?
           ORDER BY created_at DESC, id DESC
           LIMIT ?`,
          effectiveSince,
          limit,
        )
        .toArray() as unknown as MessageDbRow[]
    )
      .map((r) => this.toMessageRow(r))
      // DESC 取最近 limit 条后,翻回时间升序(UI 自上而下)。
      .reverse();

    // tombstone:full 时不回(全量重取已经只含活行);增量时回窗口内删除。
    const tombstones = full
      ? []
      : (
          this.state.storage.sql
            .exec<{ id: string }>(
              'SELECT id FROM messages WHERE deleted = 1 AND rev > ?',
              effectiveSince,
            )
            .toArray()
        ).map((r) => r.id);

    return { epoch, rev: curRev, rows, tombstones, full };
  }

  /** 成员判定(授权门):roster 命中或 owner_user_id 等于 userId。 */
  isMember(userId: string): boolean {
    const owner = this.readMeta('owner_user_id');
    if (owner && owner === userId) return true;
    const row = this.state.storage.sql
      .exec<{ c: number }>('SELECT COUNT(*) AS c FROM roster WHERE user_id = ?', userId)
      .one();
    return Number(row.c) > 0;
  }

  /** 当前 roster 全集。 */
  getRoster(): string[] {
    return this.state.storage.sql
      .exec<{ user_id: string }>('SELECT user_id FROM roster')
      .toArray()
      .map((r) => r.user_id);
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
   * 冷启动 / 驱逐回填:从 Supabase(service client,绕 RLS)一次重建消息尾 +
   * roster + conv meta,然后 backfilled=1、换新 epoch。懒触发:fetch 的读 op
   * (tail/is-member/roster)在 backfilled!=1 时先 await 本方法再服务。
   *
   * 回填查询(均在 `pendingbot` schema):
   *   - messages:WHERE conversation_id = <id> AND status != 'deleted'
   *     ORDER BY message_seq DESC, created_at DESC LIMIT N_KEEP。走
   *     idx_messages_conv_time;status='deleted' 是 §7.2 RLS 隐式滤掉的行,
   *     这里直接排除(只回填活行,tombstone 不参与冷重建)。逐条按 created_at
   *     升序 ingestMessage,使 rev 连续递增、最旧的 rev 最小。
   *   - conversation_participants:WHERE conversation_id = <id> AND
   *     participant_type = 'user'(只投影人类成员,与 webhook 写穿一致)。
   *   - conversations:单行(id),取 conversation_type → conv_type、
   *     user_id → owner_user_id 写 meta。
   *
   * 幂等性:rebuild 前清空 messages/roster 并把 cur_rev 归零,避免与残留行/旧
   * rev 串味;失败则保持 backfilled!=1,下次读再试(best-effort,冷路径仍由
   * Supabase+RLS 兜底)。
   */
  async backfill(): Promise<void> {
    const conversationId = this.state.id.name;
    if (!conversationId) {
      throw new Error('ConvProjectionDO.backfill: missing id name (must be idFromName)');
    }
    const supa = serviceClient(this.env);

    // conv 元数据(conv_type / owner)。
    const { data: conv, error: convErr } = await supa
      .from('conversations')
      .select('conversation_type, user_id')
      .eq('id', conversationId)
      .maybeSingle();
    if (convErr) throw new Error(`ConvProjectionDO.backfill conversations: ${convErr.message}`);

    // 人类 roster。
    const { data: parts, error: partsErr } = await supa
      .from('conversation_participants')
      .select('participant_id')
      .eq('conversation_id', conversationId)
      .eq('participant_type', 'user');
    if (partsErr)
      throw new Error(`ConvProjectionDO.backfill participants: ${partsErr.message}`);

    // 最近 N_KEEP 条活消息(排除 deleted)。DESC 取尾,稍后翻升序逐条摄入。
    // §7.2:语音通话回顾行(metadata.source='voice_call_summary')被 migration
    // 20260520034417 对用户 JWT 隐藏 → 冷重建也排除,与写穿喂养边界一致(投影行
    // 不带 metadata,读端点无从在读时复刻这条 RLS 过滤)。
    const { data: msgsDesc, error: msgErr } = await supa
      .from('messages')
      .select(
        'id, client_message_id, created_at, message_seq, role, status, content, log_kind, log_payload, bubble_group_id, parent_message_id, model_slug, user_id, sender_bot_id, attachments, citations, metadata',
      )
      .eq('conversation_id', conversationId)
      .neq('status', 'deleted')
      .or('metadata->>source.is.null,metadata->>source.neq.voice_call_summary')
      .order('message_seq', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(N_KEEP);
    if (msgErr) throw new Error(`ConvProjectionDO.backfill messages: ${msgErr.message}`);

    // 全部读成功后才动本地状态(失败上面已 throw,backfilled 保持未置位)。
    // 清空 + 归零 rev,确保 rebuild 是干净的(避免残留行/旧 rev 串味)。
    this.state.storage.sql.exec('DELETE FROM messages');
    this.state.storage.sql.exec('DELETE FROM roster');
    this.writeMeta('cur_rev', '0');

    // 时间升序摄入,使最旧的 rev 最小、最新的 rev 最大(与增量写穿同序)。
    const msgsAsc = (msgsDesc ?? []).slice().reverse();
    for (const m of msgsAsc) {
      this.ingestMessage({
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
        // messages.user_id 是人类发送者(与 webhook 写穿映射一致)。
        sender_user_id: m.user_id,
        sender_bot_id: m.sender_bot_id,
        attachments: m.attachments ?? null,
        citations: m.citations ?? null,
        metadata: m.metadata ?? null,
      });
    }

    for (const p of parts ?? []) {
      this.ingestRoster('add', p.participant_id);
    }

    this.setMeta({
      conv_type: conv?.conversation_type ?? 'unknown',
      owner_user_id: conv?.user_id ?? null,
    });

    // 换 epoch(让重建前签发的 cursor 失效 → 客户端 full 重取)+ 标记已回填。
    this.writeMeta('epoch', crypto.randomUUID());
    this.setMeta({ backfilled: true });
  }

  /** backfilled!=1 时先回填一次(懒触发);已回填则直接返回。 */
  private async ensureBackfilled(): Promise<void> {
    if (this.readMeta('backfilled') === '1') return;
    await this.backfill();
  }

  private toMessageRow(r: MessageDbRow): ConvMessageRow {
    const parse = (j: string | null): unknown => (j == null ? null : JSON.parse(j));
    return {
      id: r.id,
      client_message_id: r.client_message_id,
      created_at: r.created_at,
      message_seq: r.message_seq,
      role: r.role,
      status: r.status,
      content: r.content,
      log_kind: r.log_kind,
      log_payload: parse(r.log_payload_json),
      bubble_group_id: r.bubble_group_id,
      parent_message_id: r.parent_message_id,
      model_slug: r.model_slug,
      sender_user_id: r.sender_user_id,
      sender_bot_id: r.sender_bot_id,
      attachments: parse(r.attachments_json),
      citations: parse(r.citations_json),
      metadata: parse(r.metadata_json),
      rev: r.rev,
    };
  }

  // ── fetch RPC 入口 ──────────────────────────────────────────────
  // 仓库 DO 约定走 fetch(参照 wallet.ts / hub.ts):跨 DO 调用方
  // POST 一个 { op, ... } JSON 到这里,内部 switch 到上面的方法。写穿点
  // (routes/realtime-internal.ts)只 fire-and-forget 调写类 op,读 op
  // (tail/meta/roster/member)留给 E2 读端点。

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;

    switch (url.pathname) {
      case '/ingest-message': {
        this.ingestMessage(body.row as IngestMessageInput);
        return Response.json({ ok: true });
      }
      case '/mark-deleted': {
        this.markDeleted(String(body.id ?? ''));
        return Response.json({ ok: true });
      }
      case '/ingest-roster': {
        const op = body.op === 'remove' ? 'remove' : 'add';
        this.ingestRoster(op, String(body.userId ?? ''));
        return Response.json({ ok: true });
      }
      case '/set-meta': {
        this.setMeta((body.patch as ConvMetaPatch) ?? {});
        return Response.json({ ok: true });
      }
      case '/roster': {
        // 授权门读 roster:冷启动时先回填,保证踢人前的成员集可见。
        await this.ensureBackfilled();
        return Response.json({ roster: this.getRoster() });
      }
      case '/members': {
        // 投影写穿用:一次拿到 roster + owner —— 会话级变更(标题/轮次/时间戳)
        // 要扇到"能看见这个会话的每个人",owner 单独算一份(单 owner 会话的
        // roster 可能只有他自己,也可能为空)。冷启动先回填,否则会漏扇。
        await this.ensureBackfilled();
        return Response.json({
          roster: this.getRoster(),
          ownerUserId: this.getMeta().owner_user_id || null,
        });
      }
      case '/meta': {
        return Response.json({ meta: this.getMeta() });
      }
      case '/is-member': {
        // 授权门:冷启动时先回填 roster/owner,否则会误判非成员 → 误拒。
        await this.ensureBackfilled();
        return Response.json({ member: this.isMember(String(body.userId ?? '')) });
      }
      case '/tail': {
        // 读消息尾:冷启动 / 被驱逐后先从 Supabase 重建一次。
        await this.ensureBackfilled();
        return Response.json(
          this.getTail({
            sinceRev: typeof body.sinceRev === 'number' ? body.sinceRev : undefined,
            limit: typeof body.limit === 'number' ? body.limit : undefined,
            epoch: typeof body.epoch === 'string' ? body.epoch : undefined,
          }),
        );
      }
      default:
        return Response.json({ error: 'not found' }, { status: 404 });
    }
  }
}
