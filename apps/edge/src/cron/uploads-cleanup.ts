import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';

// Daily R2 cleanup. Two orphan classes:
//   1. attachments rows whose R2 object went missing (e.g. manually deleted) —
//      we mark these soft-deleted by null-ing r2_key; B2 reads ignore them.
//   2. R2 objects with no corresponding attachments row — leftover from a
//      crashed upload before the row INSERT landed. Deleted from R2.
//
// MVP scope: only class 2, and only objects older than 24h to avoid racing
// in-flight uploads. Class 1 is rare in practice (we don't expose R2 to the
// user) and can wait for a follow-up.

const STALE_HOURS = 24;
const LIST_LIMIT = 1000;

export async function cleanupOrphanUploads(env: Env): Promise<void> {
  const supa = serviceClient(env);
  const cutoff = Date.now() - STALE_HOURS * 60 * 60 * 1000;

  let cursor: string | undefined;
  let scanned = 0;
  let deleted = 0;

  for (;;) {
    const listed = await env.UPLOADS.list({ limit: LIST_LIMIT, cursor });
    scanned += listed.objects.length;

    // Filter to objects older than the cutoff. R2 returns `uploaded` as Date.
    const candidates = listed.objects.filter((o) => o.uploaded.getTime() < cutoff);
    if (candidates.length > 0) {
      const keys = candidates.map((o) => o.key);
      // Which of these have a row? Column index `idx_attachments_r2_key`
      // (B1 schema) makes the IN lookup cheap.
      const { data: known, error } = await supa
        .from('attachments')
        .select('r2_key')
        .in('r2_key', keys);
      if (error) {
        console.warn('[cron/uploads-cleanup] attachments lookup failed', error);
        return;
      }
      const knownSet = new Set((known ?? []).map((r) => r.r2_key as string));
      const orphans = keys.filter((k) => !knownSet.has(k));
      for (const key of orphans) {
        await env.UPLOADS.delete(key);
        deleted++;
      }
    }

    if (!listed.truncated) break;
    cursor = listed.cursor;
  }
  console.log('[cron/uploads-cleanup]', { scanned, deleted });
}
