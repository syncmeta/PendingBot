import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import {
  MAX_UPLOAD_BYTES,
  isSupportedImageMime,
  r2KeyFor,
} from '../lib/attachments';
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
    return c.json({ error: 'file too large', max_bytes: MAX_UPLOAD_BYTES }, 413);
  }

  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    return c.json({ error: 'invalid multipart body' }, 400);
  }

  const file = form.get('file');
  if (!(file instanceof File)) {
    return c.json({ error: 'missing file field' }, 400);
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    return c.json({ error: 'file too large', max_bytes: MAX_UPLOAD_BYTES }, 413);
  }
  if (!isSupportedImageMime(file.type)) {
    return c.json({ error: 'unsupported mime', supported: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'] }, 415);
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
      return c.json({ error: 'database', detail: error.message }, 500);
    }
    if (!data) {
      return c.json({ error: 'conversation not found or no access' }, 404);
    }
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
    return c.json({ error: 'database', detail: insertErr.message }, 500);
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

// GET /v1/uploads/:id — fetch raw bytes, gated by RLS check on attachments.
uploadRoutes.get('/:id', async (c) => {
  const userJwt = c.var.userJwt!;
  const id = c.req.param('id');

  // Fetch attachment metadata via user JWT — RLS守门 ensures the user can
  // only see attachments in their conversations or their own.
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('attachments')
    .select('r2_key, mime_type')
    .eq('id', id)
    .maybeSingle();

  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  if (!data) return c.json({ error: 'not found or no access' }, 404);

  const obj = await c.env.UPLOADS.get(data.r2_key);
  if (!obj) return c.json({ error: 'object missing' }, 410);

  return new Response(obj.body, {
    headers: {
      'Content-Type': data.mime_type,
      'Cache-Control': 'private, max-age=31536000, immutable',
      'ETag': obj.httpEtag,
    },
  });
});
