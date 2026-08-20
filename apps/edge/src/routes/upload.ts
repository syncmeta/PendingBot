import { Hono } from 'hono';
import { requireSubjectAuth, effectiveOwnerUserId } from '../lib/device-grants';
import { serviceClient, userClient } from '../lib/supabase';
import {
  DEFAULT_ATTACHMENT_QUOTA_BYTES,
  MAX_UPLOAD_BYTES,
  classifyAttachment,
  r2KeyForHash,
  sha256Hex,
} from '../lib/attachments';
import { getConfigInt } from '../lib/billing';
import { appendInventoryId, putCachedAttachment } from '../lib/attachment-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const uploadRoutes = new Hono<AppBindings>();

// Apply auth to every route in this sub-app. Accepts EITHER a supabase user
// JWT (PendingBot iOS) OR a device grant with `crew:write` (PendingCrew macOS,
// which authenticates with a `pdg_*` bearer and has no user JWT). The grant's
// `grantedByUserId` becomes the effective owner for the attachment row + quota
// (see effectiveOwnerUserId) — so a crew upload lands as a normal per-user
// attachment owned by the person who granted PendingCrew. The session path is
// unchanged: requireSubjectAuth falls through to requireSession when the bearer
// isn't `pdg_*`, sets authKind='supabase_jwt', and userId/userJwt as before.
uploadRoutes.use('*', requireSubjectAuth(['crew:write']));

// POST /v1/upload — multipart form with field 'file' (one image).
// Optional 'conversationId' field associates the attachment with a conv;
// callers leave it off if the upload precedes the conversation creation.
uploadRoutes.post('/', async (c) => {
  // Effective owner: the session user (JWT path) or the grant's
  // grantedByUserId (device-grant path). Everything below — dedup key,
  // quota, the attachments row owner — keys off this id.
  const userId = effectiveOwnerUserId(c);
  if (!userId) return jsonError(c, 401, 'unauthorized');
  // Only the session path carries a user JWT; the device-grant path has none.
  const userJwt = c.var.userJwt ?? null;

  // Quick reject by Content-Length (full multipart parse is expensive)
  const cl = c.req.header('content-length');
  if (cl && Number(cl) > MAX_UPLOAD_BYTES + 4096) {
    return jsonError(c, 413, 'attachment_too_large', { detail: { max_bytes: MAX_UPLOAD_BYTES } });
  }

  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    return jsonError(c, 400, 'invalid_body', { message: 'invalid multipart body' });
  }

  const file = form.get('file');
  if (!(file instanceof File)) {
    return jsonError(c, 400, 'attachment_missing_field', { message: 'missing file field' });
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    return jsonError(c, 413, 'attachment_too_large', { detail: { max_bytes: MAX_UPLOAD_BYTES } });
  }
  // Any MIME is accepted — images, PDFs, archives, audio, code. How the
  // file reaches the LLM is decided downstream (classifyAttachment): the
  // upload path no longer gatekeeps on type.
  const kind = classifyAttachment(file.type);

  const conversationId = form.get('conversationId');
  const conversationIdStr = typeof conversationId === 'string' && conversationId.length > 0
    ? conversationId
    : null;

  // If a conversationId is present, verify the user is a participant via RLS:
  // a select using the user JWT will return zero rows otherwise. Cheap probe.
  //
  // Only the session (user-JWT) path runs this probe — the device-grant path
  // has no user JWT to drive RLS. PendingCrew crew uploads don't pass a
  // conversationId (the attachment id is bound to a crew message at send time,
  // and `/v1/uploads/:id` re-checks membership server-side per request), so a
  // device-grant caller that *does* send one is rejected here rather than
  // silently binding it unauthenticated.
  if (conversationIdStr) {
    if (!userJwt) {
      return jsonError(c, 400, 'invalid_body', {
        message: 'conversationId is not supported on device-grant uploads',
      });
    }
    const supa = userClient(c.env, userJwt);
    const { data, error } = await supa
      .from('conversations')
      .select('id')
      .eq('id', conversationIdStr)
      .maybeSingle();
    if (error) {
      return jsonError(c, 500, 'database_error', { detail: error.message });
    }
    if (!data) {
      return jsonError(c, 404, 'conversation_no_access');
    }
  }

  // Compute content hash up-front. Cheap on these payloads (≤10 MB)
  // via WebCrypto SHA-256, and lets us short-circuit before quota
  // check + R2 write when this user has already uploaded these bytes.
  const bytes = new Uint8Array(await file.arrayBuffer());
  const contentSha256 = await sha256Hex(bytes);

  const supa = serviceClient(c.env);

  // Per-user content-addressable dedup. If the user already has an
  // attachment row for these bytes, reuse it — zero R2 write, zero
  // quota delta. The (user_id, content_sha256) UNIQUE index in
  // migration 20260512052048 makes the lookup an index seek; the
  // duplicate-key collision on insert below is the second line of
  // defense if two parallel uploads race past this check.
  {
    const { data: dup } = await supa
      .schema('pendingbot')
      .from('attachments')
      .select('id, r2_key, mime_type, byte_size, filename, created_at, conversation_id, summary, tags, summary_status')
      .eq('user_id', userId)
      .eq('content_sha256', contentSha256)
      .maybeSingle();
    if (dup) {
      const r = dup as {
        id: string;
        r2_key: string;
        mime_type: string;
        byte_size: number;
        filename: string | null;
        created_at: string;
        conversation_id: string | null;
        summary: string | null;
        tags: string[] | null;
        summary_status: string;
      };
      // Warm KV so subsequent POST /v1/messages ownership checks skip
      // Supabase. Cache the existing binding (not the current request's
      // conversationId) — the dup row's binding is what the DB enforces.
      safeWaitUntil(
        c,
        putCachedAttachment(c.env, r.id, {
          user_id: userId,
          conversation_id: r.conversation_id,
          summary: r.summary,
          tags: r.tags,
          summary_status: r.summary_status,
          created_at: r.created_at,
          mime_type: r.mime_type,
          filename: r.filename,
        }),
      );
      // Maintain the per-conv inventory list. Only the dup row's own
      // conversation_id counts — the bot-reply inventory query filters
      // on attachments.conversation_id, which the DB enforces.
      if (r.conversation_id) {
        safeWaitUntil(c, appendInventoryId(c.env, r.conversation_id, r.id));
      }
      return c.json({
        id: r.id,
        r2_key: r.r2_key,
        mime: r.mime_type,
        size: r.byte_size,
        filename: r.filename,
        url: `/v1/uploads/${r.id}`,
        created_at: r.created_at,
        deduped: true,
      });
    }
  }

  // Per-user storage quota check. Sum live byte_size for this caller
  // and reject if the new file would tip them over the cap. Cap lives
  // in billing_config so ops can tune without a deploy; fallback to
  // DEFAULT_ATTACHMENT_QUOTA_BYTES if the row is missing or the DB
  // read trips (don't let a transient outage open the gate).
  const [quotaCfg, usedRes] = await Promise.all([
    getConfigInt(supa, 'default_attachment_quota_bytes'),
    supa
      .from('attachments')
      .select('byte_size')
      .eq('user_id', userId),
  ]);
  const quotaBytes = quotaCfg && quotaCfg > 0 ? quotaCfg : DEFAULT_ATTACHMENT_QUOTA_BYTES;
  const usedBytes = ((usedRes.data as Array<{ byte_size: number | null }> | null) ?? [])
    .reduce((sum, r) => sum + (Number(r.byte_size) || 0), 0);
  if (usedBytes + file.size > quotaBytes) {
    return jsonError(c, 413, 'quota_exceeded', {
      message: '云端附件存储已达上限,请先删除一些旧的附件再试',
      detail: {
        quota_bytes: quotaBytes,
        used_bytes: usedBytes,
        attempted_bytes: file.size,
      },
    });
  }

  // Content-addressable R2 key. Two users uploading the same bytes
  // land on the same key, so R2 stores them once and we save the PUT
  // when this user's bytes are a cross-user duplicate. The per-user
  // attachments row still gets inserted below (recall + quota +
  // privacy boundaries are per-user, not per-blob).
  const key = r2KeyForHash(contentSha256, file.type);

  // HEAD before PUT — if the blob already exists from another user's
  // earlier upload, skip the write. Best-effort: any HEAD error treats
  // the object as absent and we re-PUT (idempotent on R2 — same key +
  // same bytes is a no-op overwrite, just slightly wasteful).
  const existing = await c.env.UPLOADS.head(key).catch(() => null);
  if (!existing) {
    await c.env.UPLOADS.put(key, bytes, {
      httpMetadata: { contentType: file.type },
      customMetadata: {
        // First-uploader metadata — leaving these on the shared object
        // is fine because /v1/uploads/:id never surfaces them; the
        // per-user attachment row carries its own conversation_id.
        userId,
        conversationId: conversationIdStr ?? '',
        originalName: file.name || '',
      },
    });
  }

  // Insert into pendingbot.attachments via service role — RLS would let the
  // user write their own rows but going service-role lets us write the row
  // even if the user's JWT is on a borderline state (just refreshed, etc.).
  const { data: row, error: insertErr } = await supa
    .schema('pendingbot')
    .from('attachments')
    .insert({
      user_id: userId,
      conversation_id: conversationIdStr,
      r2_key: key,
      mime_type: file.type,
      byte_size: file.size,
      filename: file.name || null,
      content_sha256: contentSha256,
      // Only images go through the vision summarizer. PDFs/files are
      // either parsed natively by the provider or fetched on demand via
      // read_attachment, so they skip summarization outright — 'skipped'
      // makes summarizeAttachment short-circuit.
      summary_status: kind === 'image' ? 'pending' : 'skipped',
      // width/height filled in once thumbnail / embed-meta generation
      // lands (see plans/.../11-scale-and-ux.md). Until then both stay
      // null, which the iOS image renderer handles.
    })
    .select('id, r2_key, mime_type, byte_size, filename, created_at')
    .single();

  if (insertErr) {
    // R2 rollback is delicate now that keys are content-addressable: a
    // delete here would wipe another user's blob if they happen to
    // reference the same bytes. Re-check ref count before each delete,
    // and bail out (leak to the orphan sweep) when in doubt.
    const safeRollback = async () => {
      // Was the object even ours to write? If `existing` was non-null
      // before the PUT, we never wrote — nothing to roll back.
      if (existing) return;
      const { count } = await supa
        .schema('pendingbot')
        .from('attachments')
        .select('id', { count: 'exact', head: true })
        .eq('r2_key', key);
      if ((count ?? 0) > 0) return; // someone else has a row, leave it
      await c.env.UPLOADS.delete(key).catch((err) => {
        console.warn('[upload] R2 rollback failed', { key, err });
      });
    };

    // Race fallback: a parallel upload of the same bytes hit the
    // (user_id, content_sha256) UNIQUE index in between our dedup
    // SELECT and this INSERT. Re-fetch the winning row and return it.
    if ((insertErr as { code?: string }).code === '23505') {
      const { data: winner } = await supa
        .schema('pendingbot')
        .from('attachments')
        .select('id, r2_key, mime_type, byte_size, filename, created_at, conversation_id, summary, tags, summary_status')
        .eq('user_id', userId)
        .eq('content_sha256', contentSha256)
        .maybeSingle();
      await safeRollback();
      if (winner) {
        const r = winner as {
          id: string;
          r2_key: string;
          mime_type: string;
          byte_size: number;
          filename: string | null;
          created_at: string;
          conversation_id: string | null;
          summary: string | null;
          tags: string[] | null;
          summary_status: string;
        };
        safeWaitUntil(
          c,
          putCachedAttachment(c.env, r.id, {
            user_id: userId,
            conversation_id: r.conversation_id,
            summary: r.summary,
            tags: r.tags,
            summary_status: r.summary_status,
            created_at: r.created_at,
            mime_type: r.mime_type,
            filename: r.filename,
          }),
        );
        if (r.conversation_id) {
          safeWaitUntil(c, appendInventoryId(c.env, r.conversation_id, r.id));
        }
        return c.json({
          id: r.id,
          r2_key: r.r2_key,
          mime: r.mime_type,
          size: r.byte_size,
          filename: r.filename,
          url: `/v1/uploads/${r.id}`,
          created_at: r.created_at,
          deduped: true,
        });
      }
    }
    await safeRollback();
    return jsonError(c, 500, 'database_error', { detail: insertErr.message });
  }

  // Warm KV with the freshly-inserted row. Summary/tags start unset —
  // the vision summarizer will patch them when it runs.
  safeWaitUntil(
    c,
    putCachedAttachment(c.env, row.id, {
      user_id: userId,
      conversation_id: conversationIdStr,
      summary: null,
      tags: null,
      summary_status: kind === 'image' ? 'pending' : 'skipped',
      created_at: row.created_at,
      mime_type: row.mime_type,
      filename: row.filename,
    }),
  );
  if (conversationIdStr) {
    safeWaitUntil(c, appendInventoryId(c.env, conversationIdStr, row.id));
  }

  return c.json({
    id: row.id,
    r2_key: row.r2_key,
    mime: row.mime_type,
    size: row.byte_size,
    filename: row.filename,
    url: `/v1/uploads/${row.id}`,    // Worker-served URL (auth-gated)
    created_at: row.created_at,
  });
});

// GET /v1/uploads/:id — fetch raw bytes.
//
// Access model (strict scope):
//
//   1. The uploader (attachments.user_id == caller) — always served.
//   2. A *current* participant of a conversation that has a *non-deleted*
//      message referencing this attachment — served. Membership lapses
//      (left the group) revoke server-side access immediately; deleted
//      messages (status='deleted') drop their attachments off-limits
//      even for users who'd previously seen them.
//   3. Everyone else — 404 (same shape as "doesn't exist" so we don't
//      help enumerate attachment ids).
//
// All checks happen here, server-side, via service role. RLS on
// `attachments` is uploader-only now (migration 20260512042940), so a
// direct DB read by anyone other than the uploader fails-closed.
uploadRoutes.get('/:id', async (c) => {
  // Effective viewer: session user, or the user the device grant acts for.
  // The participant / avatar checks below all key off this id, so a
  // PendingCrew device grant sees exactly what its granting user would.
  const userId = effectiveOwnerUserId(c);
  if (!userId) return jsonError(c, 401, 'unauthorized');
  const id = c.req.param('id');

  const supa = serviceClient(c.env);

  const { data: att, error: attErr } = await supa
    .from('attachments')
    .select('id, user_id, r2_key, mime_type')
    .eq('id', id)
    .maybeSingle();

  if (attErr) return jsonError(c, 500, 'database_error', { detail: attErr.message });
  if (!att) return jsonError(c, 404, 'not_found');

  let allowed = att.user_id === userId;

  if (!allowed) {
    // Find a non-deleted message that references this attachment and
    // is in a conversation the caller is currently a participant of.
    // attachments jsonb shape: { ids: [uuid, …] }
    const { data: msgRows, error: msgErr } = await supa
      .from('messages')
      .select('conversation_id, status')
      .filter('attachments->ids', 'cs', JSON.stringify([id]))
      .neq('status', 'deleted');
    if (msgErr) return jsonError(c, 500, 'database_error', { detail: msgErr.message });

    if (msgRows && msgRows.length > 0) {
      const convIds = Array.from(
        new Set(msgRows.map((r) => r.conversation_id as string)),
      );
      const { data: memberRows, error: memberErr } = await supa
        .from('conversation_participants')
        .select('conversation_id')
        .eq('participant_type', 'user')
        .eq('participant_id', userId)
        .in('conversation_id', convIds);
      if (memberErr) return jsonError(c, 500, 'database_error', { detail: memberErr.message });
      allowed = !!memberRows && memberRows.length > 0;
    }
  }

  if (!allowed) {
    // Avatar exception (decisions.md D3 part 2): a user's profile avatar is
    // viewable by any authenticated caller that presents its attachment id.
    // The id is non-enumerable (uuid) and only surfaces from legitimate
    // places — handle lookup (加好友 preview) and conversation/group member
    // lists (群成员). This makes those two contexts' avatars load while
    // keeping everything else gated: only the *image bytes* are served here;
    // attachment *metadata* (r2_key, filename, …) stays RLS-gated (migration
    // 20260601080625), and chat attachments stay message-reference gated above.
    const { data: avatarRow, error: avatarErr } = await supa
      .from('users')
      .select('id')
      .eq('avatar_path', id)
      .maybeSingle();
    if (avatarErr) return jsonError(c, 500, 'database_error', { detail: avatarErr.message });
    if (avatarRow) allowed = true;
  }

  if (!allowed) return jsonError(c, 404, 'not_found');

  const obj = await c.env.UPLOADS.get(att.r2_key);
  if (!obj) return jsonError(c, 410, 'attachment_object_missing');

  return new Response(obj.body, {
    headers: {
      'Content-Type': att.mime_type,
      'Cache-Control': 'private, max-age=31536000, immutable',
      'ETag': obj.httpEtag,
    },
  });
});
