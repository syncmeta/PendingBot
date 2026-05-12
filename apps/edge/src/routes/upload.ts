import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import {
  DEFAULT_ATTACHMENT_QUOTA_BYTES,
  MAX_UPLOAD_BYTES,
  isSupportedImageMime,
  r2KeyFor,
} from '../lib/attachments';
import { getConfigInt } from '../lib/billing';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const uploadRoutes = new Hono<AppBindings>();

// Apply auth to every route in this sub-app.
uploadRoutes.use('*', requireSession());

// POST /v1/upload — multipart form with field 'file' (one image).
// Optional 'conversationId' field associates the attachment with a conv;
// callers leave it off if the upload precedes the conversation creation.
uploadRoutes.post('/', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

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
  if (!isSupportedImageMime(file.type)) {
    return jsonError(c, 415, 'attachment_unsupported_mime', {
      detail: { supported: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'] },
    });
  }

  const conversationId = form.get('conversationId');
  const conversationIdStr = typeof conversationId === 'string' && conversationId.length > 0
    ? conversationId
    : null;

  // If a conversationId is present, verify the user is a participant via RLS:
  // a select using the user JWT will return zero rows otherwise. Cheap probe.
  if (conversationIdStr) {
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

  // Per-user storage quota check. Sum live byte_size for this caller
  // and reject if the new file would tip them over the cap. Cap lives
  // in billing_config so ops can tune without a deploy; fallback to
  // DEFAULT_ATTACHMENT_QUOTA_BYTES if the row is missing or the DB
  // read trips (don't let a transient outage open the gate).
  const supaForQuota = serviceClient(c.env);
  const [quotaCfg, usedRes] = await Promise.all([
    getConfigInt(supaForQuota, 'default_attachment_quota_bytes'),
    supaForQuota
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

  // Allocate id + R2 key. UUID v7 keeps the bucket sortable by time.
  const id = crypto.randomUUID();          // V4 client-side; DB row id is V7 server-side
  const key = r2KeyFor(id, file.type);
  const bytes = new Uint8Array(await file.arrayBuffer());

  await c.env.UPLOADS.put(key, bytes, {
    httpMetadata: { contentType: file.type },
    customMetadata: {
      userId,
      conversationId: conversationIdStr ?? '',
      originalName: file.name || '',
    },
  });

  // Insert into pendingbot.attachments via service role — RLS would let the
  // user write their own rows but going service-role lets us write the row
  // even if the user's JWT is on a borderline state (just refreshed, etc.).
  const supa = serviceClient(c.env);
  const { data: row, error: insertErr } = await supa
    .schema('pendingbot')
    .from('attachments')
    .insert({
      user_id: userId,
      conversation_id: conversationIdStr,
      r2_key: key,
      mime_type: file.type,
      byte_size: file.size,
      // width/height: TODO — generate via image-resizing or embed-meta when
      // we run thumbnail generation (see plans/.../11-scale-and-ux.md).
    })
    .select('id, r2_key, mime_type, byte_size, created_at')
    .single();

  if (insertErr) {
    // Best-effort R2 rollback. If the delete fails the orphan upload
    // sweep (cron 04:00 UTC) will reap the key on its next run.
    await c.env.UPLOADS.delete(key).catch((err) => {
      console.warn('[upload] R2 rollback failed', { key, err });
    });
    return jsonError(c, 500, 'database_error', { detail: insertErr.message });
  }

  return c.json({
    id: row.id,
    r2_key: row.r2_key,
    mime: row.mime_type,
    size: row.byte_size,
    url: `/v1/uploads/${row.id}`,    // Worker-served URL (auth-gated)
    created_at: row.created_at,
  });
});

// GET /v1/uploads/:id — fetch raw bytes.
//
// Access model (strict scope, post May-2026 audit):
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
  const userId = c.var.userId!;
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
