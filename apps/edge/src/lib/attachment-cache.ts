// KV-backed cache for attachment metadata so the pre-stream path in
// POST /v1/messages and the inventory build in bot-reply both skip
// Supabase.
//
// Two key types:
//   att:${id}            → CachedAttachment (ownership + inventory fields)
//   conv-atts:${convId}  → ordered attachment-id list for the conv,
//                          cap INVENTORY_CAP, ASC by created_at
//
// Write surfaces:
//   - POST /v1/upload     (fresh insert, dedup return, race winner)
//   - vision summarizer   (after summary/status lands)
//   - POST /v1/messages   (recall — remove from list, delete att)
// Reads on miss fall through to Supabase, then warm KV.

import type { SupabaseClient } from './supabase';
import type { Env } from '../types';

const ATT_PREFIX = 'att:';
const CONV_ATTS_PREFIX = 'conv-atts:';
const INVENTORY_CAP = 30;

export interface CachedAttachment {
  user_id: string;
  /// May be null at upload time when the client hadn't picked a conv
  /// yet. The ownership check tolerates null (first-bind is allowed).
  conversation_id: string | null;
  /// Inventory fields — null when the attachment hasn't been
  /// summarized yet. The vision summarizer writes these in.
  summary?: string | null;
  tags?: string[] | null;
  summary_status?: string | null;
  /// ISO 8601 timestamp; used for inventory ordering.
  created_at?: string | null;
  /// MIME + original filename — drive how the prompt builder lists the
  /// attachment (image inventory vs file inventory). Absent on cache
  /// entries written before arbitrary-file support; treated as an image
  /// then, which matches the legacy invariant (all attachments were images).
  mime_type?: string | null;
  filename?: string | null;
}

/// Parallel KV read for a list of attachment ids. Returns a Map with
/// `null` for misses so the caller can decide what to fall back on.
export async function getCachedAttachments(
  env: Env,
  ids: readonly string[],
): Promise<Map<string, CachedAttachment | null>> {
  const out = new Map<string, CachedAttachment | null>();
  if (ids.length === 0) return out;
  const results = await Promise.all(
    ids.map((id) => env.MEMORY.get<CachedAttachment>(ATT_PREFIX + id, 'json')),
  );
  ids.forEach((id, i) => out.set(id, results[i] ?? null));
  return out;
}

export async function putCachedAttachment(
  env: Env,
  id: string,
  data: CachedAttachment,
): Promise<void> {
  await env.MEMORY.put(ATT_PREFIX + id, JSON.stringify(data));
}

export async function deleteCachedAttachment(env: Env, id: string): Promise<void> {
  await env.MEMORY.delete(ATT_PREFIX + id);
}

/// Patch a subset of fields on a cached attachment. Reads the current
/// row (defaults to a fresh skeleton if missing — caller is responsible
/// for re-warming ownership via a separate write if the row was cold).
export async function patchCachedAttachment(
  env: Env,
  id: string,
  patch: Partial<CachedAttachment>,
): Promise<void> {
  const current = (await env.MEMORY.get<CachedAttachment>(ATT_PREFIX + id, 'json')) ?? null;
  if (!current) {
    // Don't materialize a partial row from nothing — we'd be missing
    // ownership fields. Leave the read-through to repopulate later.
    return;
  }
  const next = { ...current, ...patch };
  await env.MEMORY.put(ATT_PREFIX + id, JSON.stringify(next));
}

// ---------------------------------------------------------------------------
// Inventory list — ordered attachment ids per conversation.
// ---------------------------------------------------------------------------

export async function getInventoryIds(env: Env, conversationId: string): Promise<string[] | null> {
  return env.MEMORY.get<string[]>(CONV_ATTS_PREFIX + conversationId, 'json');
}

export async function putInventoryIds(
  env: Env,
  conversationId: string,
  ids: string[],
): Promise<void> {
  await env.MEMORY.put(CONV_ATTS_PREFIX + conversationId, JSON.stringify(ids));
}

/// Append an id to the inventory list for a conv (creating it if
/// absent). Drops the head when over INVENTORY_CAP so the list mirrors
/// the bot-reply query's `limit(30)`. Idempotent on the id already
/// being present.
export async function appendInventoryId(
  env: Env,
  conversationId: string,
  attachmentId: string,
): Promise<void> {
  const existing = (await getInventoryIds(env, conversationId)) ?? [];
  if (existing.includes(attachmentId)) return;
  const next = [...existing, attachmentId];
  while (next.length > INVENTORY_CAP) next.shift();
  await putInventoryIds(env, conversationId, next);
}

/// Remove ids from the inventory list. No-op if the conv has no list
/// or if none of the ids are present.
export async function removeInventoryIds(
  env: Env,
  conversationId: string,
  ids: readonly string[],
): Promise<void> {
  const existing = await getInventoryIds(env, conversationId);
  if (!existing || existing.length === 0) return;
  const remove = new Set(ids);
  const next = existing.filter((id) => !remove.has(id));
  if (next.length === existing.length) return;
  await putInventoryIds(env, conversationId, next);
}

export interface InventoryRow {
  id: string;
  summary: string | null;
  tags: string[];
  status: string;
  created_at: string | null;
  mime: string | null;
  filename: string | null;
}

/// Fetch the historical attachment inventory for a conv — mirrors the
/// `select(id, summary, tags, summary_status, created_at)
///   .eq('conversation_id', convId).order('created_at').limit(30)` query
/// used by the bot-reply prompt builder. Reads from KV; on miss (or
/// stale row) falls back to Supabase and warms KV.
export async function resolveInventory(
  env: Env,
  supa: SupabaseClient,
  conversationId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<InventoryRow[]> {
  const ids = await getInventoryIds(env, conversationId);
  if (ids && ids.length > 0) {
    const cached = await Promise.all(
      ids.map((id) => env.MEMORY.get<CachedAttachment>(ATT_PREFIX + id, 'json')),
    );
    const missing: string[] = [];
    const rows: Array<InventoryRow | null> = ids.map((id, i) => {
      const c = cached[i];
      if (!c) {
        missing.push(id);
        return null;
      }
      return {
        id,
        summary: c.summary ?? null,
        tags: c.tags ?? [],
        status: c.summary_status ?? 'pending',
        created_at: c.created_at ?? null,
        mime: c.mime_type ?? null,
        filename: c.filename ?? null,
      };
    });
    if (missing.length === 0) {
      return rows.filter((r): r is InventoryRow => r !== null);
    }
    // A few atts in the list weren't cached individually — fall through
    // to a Supabase fetch for just those, warm KV, then merge.
    const { data, error } = await supa
      .from('attachments')
      .select('id, summary, tags, summary_status, created_at, user_id, conversation_id, mime_type, filename')
      .in('id', missing);
    if (!error && data) {
      const rowMap = new Map(
        (data as Array<{
          id: string;
          summary: string | null;
          tags: string[] | null;
          summary_status: string;
          created_at: string;
          user_id: string;
          conversation_id: string | null;
          mime_type: string | null;
          filename: string | null;
        }>).map((r) => [r.id, r]),
      );
      waitUntil(
        Promise.all(
          Array.from(rowMap.values()).map((r) =>
            putCachedAttachment(env, r.id, {
              user_id: r.user_id,
              conversation_id: r.conversation_id,
              summary: r.summary,
              tags: r.tags,
              summary_status: r.summary_status,
              created_at: r.created_at,
              mime_type: r.mime_type,
              filename: r.filename,
            }),
          ),
        ).then(() => undefined),
      );
      ids.forEach((id, i) => {
        if (rows[i] != null) return;
        const r = rowMap.get(id);
        if (!r) return;
        rows[i] = {
          id,
          summary: r.summary,
          tags: r.tags ?? [],
          status: r.summary_status,
          created_at: r.created_at,
          mime: r.mime_type,
          filename: r.filename,
        };
      });
    }
    return rows.filter((r): r is InventoryRow => r !== null);
  }

  // No cached list — fall back to a single Supabase query and warm both
  // the list and the per-id rows.
  const { data, error } = await supa
    .from('attachments')
    .select('id, summary, tags, summary_status, created_at, user_id, conversation_id, mime_type, filename')
    .eq('conversation_id', conversationId)
    .order('created_at', { ascending: true })
    .limit(INVENTORY_CAP);
  if (error || !data) return [];
  const fetched = data as Array<{
    id: string;
    summary: string | null;
    tags: string[] | null;
    summary_status: string;
    created_at: string;
    user_id: string;
    conversation_id: string | null;
    mime_type: string | null;
    filename: string | null;
  }>;
  waitUntil(
    (async () => {
      await Promise.all(
        fetched.map((r) =>
          putCachedAttachment(env, r.id, {
            user_id: r.user_id,
            conversation_id: r.conversation_id,
            summary: r.summary,
            tags: r.tags,
            summary_status: r.summary_status,
            created_at: r.created_at,
            mime_type: r.mime_type,
            filename: r.filename,
          }),
        ),
      );
      await putInventoryIds(env, conversationId, fetched.map((r) => r.id));
    })(),
  );
  return fetched.map((r) => ({
    id: r.id,
    summary: r.summary,
    tags: r.tags ?? [],
    status: r.summary_status,
    created_at: r.created_at,
    mime: r.mime_type,
    filename: r.filename,
  }));
}

export interface AttachmentOwnership {
  id: string;
  user_id: string;
  conversation_id: string | null;
}

/// Resolve ownership for a batch of attachment ids. Reads KV first; for
/// any misses, falls back to Supabase and warms KV for next time
/// (warming is fire-and-forget via the supplied waitUntil; if the caller
/// has no execution context, pass a no-op).
///
/// Returns null when one or more ids couldn't be resolved at all — the
/// caller should treat that as `attachment_not_found`.
export async function resolveAttachmentOwnership(
  env: Env,
  supa: SupabaseClient,
  ids: readonly string[],
  waitUntil: (p: Promise<unknown>) => void,
): Promise<AttachmentOwnership[] | null> {
  if (ids.length === 0) return [];
  const cached = await getCachedAttachments(env, ids);
  const misses: string[] = [];
  for (const id of ids) {
    if (!cached.get(id)) misses.push(id);
  }
  if (misses.length === 0) {
    return ids.map((id) => {
      const c = cached.get(id)!;
      return { id, user_id: c.user_id, conversation_id: c.conversation_id };
    });
  }
  const { data, error } = await supa
    .from('attachments')
    .select('id, user_id, conversation_id, mime_type, filename')
    .in('id', misses);
  if (error) throw error;
  if (!data) return null;
  const dbMap = new Map(
    (data as Array<{
      id: string;
      user_id: string;
      conversation_id: string | null;
      mime_type: string | null;
      filename: string | null;
    }>).map((r) => [r.id, r]),
  );
  // Warm KV for the misses we successfully fetched.
  waitUntil(
    Promise.all(
      Array.from(dbMap.values()).map((r) =>
        putCachedAttachment(env, r.id, {
          user_id: r.user_id,
          conversation_id: r.conversation_id,
          mime_type: r.mime_type,
          filename: r.filename,
        }),
      ),
    ).then(() => undefined),
  );
  const out: AttachmentOwnership[] = [];
  for (const id of ids) {
    const fromCache = cached.get(id);
    if (fromCache) {
      out.push({ id, user_id: fromCache.user_id, conversation_id: fromCache.conversation_id });
      continue;
    }
    const fromDb = dbMap.get(id);
    if (!fromDb) return null;
    out.push({ id, user_id: fromDb.user_id, conversation_id: fromDb.conversation_id });
  }
  return out;
}
