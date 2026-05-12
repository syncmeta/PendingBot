// KV-backed cache for the attachment ownership tuple
// (user_id, conversation_id) so the pre-stream check in POST
// /v1/messages can validate without hitting Supabase.
//
// Attachments are written once at upload time and not mutated thereafter
// (apart from delete via recall and `conversation_id` being set when the
// upload route knows it). That makes them a clean write-through fit:
// upload routes warm KV, recall + cleanup invalidate.

import type { SupabaseClient } from './supabase';
import type { Env } from '../types';

const ATT_PREFIX = 'att:';

export interface CachedAttachment {
  user_id: string;
  /// May be null at upload time when the client hadn't picked a conv
  /// yet. The ownership check tolerates null (first-bind is allowed).
  conversation_id: string | null;
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
    .select('id, user_id, conversation_id')
    .in('id', misses);
  if (error || !data) return null;
  const dbMap = new Map(
    (data as Array<{ id: string; user_id: string; conversation_id: string | null }>).map((r) => [r.id, r]),
  );
  // Warm KV for the misses we successfully fetched.
  waitUntil(
    Promise.all(
      Array.from(dbMap.values()).map((r) =>
        putCachedAttachment(env, r.id, {
          user_id: r.user_id,
          conversation_id: r.conversation_id,
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
