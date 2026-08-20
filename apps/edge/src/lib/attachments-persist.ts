// Generic "bot just produced some bytes, turn them into an attachment
// row" helper. Extracted from bot-reply/index.ts where it lived as
// persistGeneratedImage (PNG-only, base64-in). Now any tool that
// generates / fetches image bytes (image_generation, send_images, …)
// runs through the same R2 + dedup + 23505-race path.
//
// Dedup pattern matches routes/upload.ts: SELECT-then-INSERT with a
// 23505 race fallback. We can't use `.upsert(..., { onConflict })`
// here because the dedup index `idx_attachments_user_sha256` is
// *partial* (`WHERE content_sha256 IS NOT NULL`), and PostgREST's
// `ON CONFLICT (cols)` syntax can't auto-arbitrate against a partial
// index — PG returns "no unique or exclusion constraint matching the
// ON CONFLICT specification" and the upsert silently fails.

import type { Env } from '../types';
import type { serviceClient } from './supabase';
import { r2KeyForHash, sha256Hex } from './attachments';

export async function persistAttachmentBytes(
  env: Env,
  supa: ReturnType<typeof serviceClient>,
  userId: string,
  conversationId: string,
  bytes: Uint8Array,
  mime: string,
): Promise<string | null> {
  try {
    const sha = await sha256Hex(bytes);
    const key = r2KeyForHash(sha, mime);

    // Fast path: this user already has a row for these bytes. Reuse it
    // and skip the R2 write entirely.
    {
      const { data: dup } = await supa
        .from('attachments')
        .select('id')
        .eq('user_id', userId)
        .eq('content_sha256', sha)
        .maybeSingle();
      if (dup) return (dup as { id: string }).id;
    }

    const existing = await env.UPLOADS.head(key).catch(() => null);
    if (!existing) {
      await env.UPLOADS.put(key, bytes, {
        httpMetadata: { contentType: mime },
      });
    }

    const { data, error } = await supa
      .from('attachments')
      .insert({
        user_id: userId,
        conversation_id: conversationId,
        r2_key: key,
        mime_type: mime,
        byte_size: bytes.length,
        content_sha256: sha,
      })
      .select('id')
      .single();

    // Race fallback: a parallel turn (or concurrent user upload of the
    // same bytes) hit the partial UNIQUE between our SELECT and INSERT.
    // Re-fetch the winner.
    if (error) {
      if ((error as { code?: string }).code === '23505') {
        const { data: winner } = await supa
          .from('attachments')
          .select('id')
          .eq('user_id', userId)
          .eq('content_sha256', sha)
          .maybeSingle();
        if (winner) return (winner as { id: string }).id;
      }
      console.warn('[attachments-persist] insert failed', error.message);
      return null;
    }
    return data.id as string;
  } catch (err) {
    console.warn('[attachments-persist] failed', err);
    return null;
  }
}
