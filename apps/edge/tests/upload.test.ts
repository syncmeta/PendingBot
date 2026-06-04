import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type Row,
} from './_helpers/fake-supabase';
import { sha256Hex } from '../src/lib/attachments';
import type { AppBindings } from '../src/types';

// Tests for /v1/upload routes. Two surfaces:
//
//   POST /v1/upload  — multipart, dedup + quota + R2 PUT
//   GET  /v1/uploads/:id — strict-scope access model
//
// The interesting product invariants pinned here:
//   • Per-user dedup short-circuits R2 entirely (no PUT, no quota tick)
//   • Cross-user blob dedup HEAD-skips the PUT but still inserts a row
//   • Quota gate uses billing_config when present, falls back to default
//   • Access model: uploader OR current participant of a non-deleted
//     message referencing this id. Recall (status='deleted') revokes
//     even previously-accessible reads.

vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<{
    Bindings: { SUPABASE_URL: string; SUPABASE_JWT_SECRET: string };
    Variables: { userId?: string; userJwt?: string };
  }> => async (c, next) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', u);
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let uploadRoutes: any;

interface R2Mock {
  store: Map<string, Uint8Array>;
  puts: string[];
  heads: string[];
  deletes: string[];
}

function makeR2Mock(): R2Mock {
  const store = new Map<string, Uint8Array>();
  const puts: string[] = [];
  const heads: string[] = [];
  const deletes: string[] = [];
  return { store, puts, heads, deletes };
}

function bindR2(env: Record<string, unknown>, r2: R2Mock) {
  env.UPLOADS = {
    async put(key: string, bytes: Uint8Array) {
      r2.store.set(key, bytes);
      r2.puts.push(key);
    },
    async head(key: string) {
      r2.heads.push(key);
      const v = r2.store.get(key);
      return v ? { size: v.byteLength } : null;
    },
    async get(key: string) {
      const v = r2.store.get(key);
      if (!v) return null;
      return {
        body: v,
        httpEtag: '"abc"',
      };
    },
    async delete(key: string) {
      r2.store.delete(key);
      r2.deletes.push(key);
    },
  };
}

beforeEach(async () => {
  ({ uploadRoutes } = await import('../src/routes/upload'));
});

// SHA-256 a device-grant token the way lib/device-grants.ts hashes it, so a
// seeded `subject_device_grants.token_hash` matches `Bearer <token>`.
async function sha256HexString(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

// Seed an active PendingCrew-style device grant. `grantedByUserId` is the
// effective owner the upload should attribute the attachment row to.
async function makeDeviceGrant(
  token: string,
  grantedByUserId: string,
  scopes: string[],
): Promise<Row> {
  return {
    id: 'grant-1',
    subject_id: 'subject-1',
    granted_by_user_id: grantedByUserId,
    token_hash: await sha256HexString(token),
    grant_kind: 'pendingcrew_control',
    scopes,
    app_kind: 'pendingcrew_macos',
    status: 'active',
    expires_at: '2099-01-01T00:00:00Z',
    last_used_at: null,
  };
}

async function post(
  env: ReturnType<typeof makeFakeEnv>,
  userId: string,
  formFields: Record<string, string | { file: Uint8Array; name: string; type: string }>,
  opts?: { bearer?: string },
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/upload', uploadRoutes);

  const fd = new FormData();
  for (const [k, v] of Object.entries(formFields)) {
    if (typeof v === 'string') {
      fd.append(k, v);
    } else {
      fd.append(k, new File([new Uint8Array(v.file)], v.name, { type: v.type }));
    }
  }

  // A `pdg_*` bearer drives the real device-grant branch of requireSubjectAuth
  // (the requireSession mock only kicks in when no such bearer is present), so
  // these two auth paths exercise different code without a second mock.
  const headers: Record<string, string> = opts?.bearer
    ? { authorization: `Bearer ${opts.bearer}` }
    : { 'x-test-user-id': userId };

  const res = await app.request(
    '/v1/upload',
    { method: 'POST', headers, body: fd },
    env,
  );
  let body: Record<string, unknown> = {};
  try {
    body = (await res.json()) as Record<string, unknown>;
  } catch {
    /* ignore */
  }
  return { status: res.status, body };
}

async function get(
  env: ReturnType<typeof makeFakeEnv>,
  userId: string,
  id: string,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/uploads', uploadRoutes);
  const res = await app.request(
    `/v1/uploads/${id}`,
    { headers: { 'x-test-user-id': userId } },
    env,
  );
  let body: Record<string, unknown> = {};
  try {
    body = (await res.json()) as Record<string, unknown>;
  } catch {
    /* ignore */
  }
  return { status: res.status, body };
}

// Tiny PNG-ish payload — content doesn't matter (no image decoding), only
// size + sha256 do. We deliberately use a few different byte patterns
// across tests so the (user_id, content_sha256) dedup index distinguishes them.
const BYTES_A = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x01]);
const BYTES_B = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x02]);

describe('POST /v1/upload — input validation', () => {
  it('accepts arbitrary non-image mimes and skips summarization', async () => {
    const env = makeFakeEnv(makeFakeDb({ attachments: [], billing_config: [] }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());
    const r = await post(env, 'alice', {
      file: { file: BYTES_A, name: 'archive.zip', type: 'application/zip' },
    });
    expect(r.status).toBe(200);
    expect(r.body.filename).toBe('archive.zip');

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts).toHaveLength(1);
    const row = db.inserts[0].row as { filename: string; summary_status: string };
    expect(row.filename).toBe('archive.zip');
    // Non-image → vision summarizer is bypassed.
    expect(row.summary_status).toBe('skipped');
  });

  it('rejects missing file field with 400 attachment_missing_field', async () => {
    const env = makeFakeEnv(makeFakeDb({ attachments: [], billing_config: [] }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());
    const r = await post(env, 'alice', { other: 'field' });
    expect(r.status).toBe(400);
    expect((r.body.error as { code?: string }).code).toBe('attachment_missing_field');
  });
});

describe('POST /v1/upload — per-user dedup', () => {
  it('returns the existing row with deduped:true and skips R2 entirely', async () => {
    const hash = await sha256Hex(BYTES_A);
    const seed: Row[] = [
      {
        id: 'att-existing',
        user_id: 'alice',
        content_sha256: hash,
        r2_key: 'blobs/h.png',
        mime_type: 'image/png',
        byte_size: 100,
        created_at: '2026-05-12T00:00:00Z',
      },
    ];
    const env = makeFakeEnv(makeFakeDb({ attachments: seed, billing_config: [] }));
    const r2 = makeR2Mock();
    bindR2(env as unknown as Record<string, unknown>, r2);

    const r = await post(env, 'alice', {
      file: { file: BYTES_A, name: 'a.png', type: 'image/png' },
    });
    expect(r.status).toBe(200);
    expect(r.body.id).toBe('att-existing');
    expect(r.body.deduped).toBe(true);

    expect(r2.puts).toEqual([]);
    expect(r2.heads).toEqual([]);
    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts).toEqual([]);
  });
});

describe('POST /v1/upload — cross-user content-addressable dedup', () => {
  it('HEAD-skips the R2 PUT when another user already uploaded the same bytes', async () => {
    const hash = await sha256Hex(BYTES_A);
    const sharedKey = `blobs/${hash}.png`;
    // bob already uploaded these bytes
    const seed: Row[] = [
      {
        id: 'att-bob',
        user_id: 'bob',
        content_sha256: hash,
        r2_key: sharedKey,
        mime_type: 'image/png',
        byte_size: BYTES_A.length,
        created_at: '2026-05-12T00:00:00Z',
      },
    ];
    const env = makeFakeEnv(makeFakeDb({ attachments: seed, billing_config: [] }));
    const r2 = makeR2Mock();
    // Pre-populate R2 with bob's bytes
    r2.store.set(sharedKey, BYTES_A);
    bindR2(env as unknown as Record<string, unknown>, r2);

    const r = await post(env, 'alice', {
      file: { file: BYTES_A, name: 'a.png', type: 'image/png' },
    });
    expect(r.status).toBe(200);
    expect(r.body.r2_key).toBe(sharedKey);

    // HEAD was performed, PUT was skipped
    expect(r2.heads).toEqual([sharedKey]);
    expect(r2.puts).toEqual([]);

    // A new attachments row was inserted for alice referencing the same r2_key
    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts).toHaveLength(1);
    expect((db.inserts[0].row as { user_id: string }).user_id).toBe('alice');
    expect((db.inserts[0].row as { r2_key: string }).r2_key).toBe(sharedKey);
  });
});

describe('POST /v1/upload — quota gate', () => {
  it('rejects with 413 quota_exceeded when the new file would tip the user over', async () => {
    // Tiny quota (50 bytes) lets us tip it over with a small file —
    // staying well under MAX_UPLOAD_BYTES (25 MiB) so the
    // attachment_too_large gate above doesn't fire instead.
    const seed: Row[] = [
      { id: 'att-old', user_id: 'alice', byte_size: 45, content_sha256: 'xx', r2_key: 'k', mime_type: 'image/png' },
    ];
    const billing: Row[] = [
      { key: 'default_attachment_quota_bytes', value: 50 },
    ];
    const env = makeFakeEnv(makeFakeDb({ attachments: seed, billing_config: billing }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());

    // 9 bytes file → 45 + 9 = 54 > 50, over the cap
    const r = await post(env, 'alice', {
      file: { file: BYTES_A, name: 'a.png', type: 'image/png' },
    });
    expect(r.status).toBe(413);
    expect((r.body.error as { code?: string }).code).toBe('quota_exceeded');
    expect(((r.body.error as { detail?: { quota_bytes: number } }).detail)?.quota_bytes).toBe(50);
  });

  it('uses the 1 GiB default when billing_config has no row', async () => {
    // No billing_config row → fallback to DEFAULT_ATTACHMENT_QUOTA_BYTES.
    // 512 MiB used + a tiny file → well under 1 GiB, should succeed.
    const seed: Row[] = [
      { id: 'att-old', user_id: 'alice', byte_size: 512 * 1024 * 1024, content_sha256: 'xx', r2_key: 'k', mime_type: 'image/png' },
    ];
    const env = makeFakeEnv(makeFakeDb({ attachments: seed, billing_config: [] }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());

    const r = await post(env, 'alice', {
      file: { file: BYTES_A, name: 'a.png', type: 'image/png' },
    });
    expect(r.status).toBe(200);
  });
});

describe('POST /v1/upload — happy path', () => {
  it('writes the file to R2 with a content-addressable key + inserts an attachments row', async () => {
    const env = makeFakeEnv(makeFakeDb({ attachments: [], billing_config: [] }));
    const r2 = makeR2Mock();
    bindR2(env as unknown as Record<string, unknown>, r2);

    const r = await post(env, 'alice', {
      file: { file: BYTES_B, name: 'b.png', type: 'image/png' },
    });
    expect(r.status).toBe(200);

    const hash = await sha256Hex(BYTES_B);
    const expectedKey = `blobs/${hash}.png`;
    expect(r2.heads).toEqual([expectedKey]); // we HEAD first
    expect(r2.puts).toEqual([expectedKey]);  // then PUT (no existing object)
    expect(r2.store.get(expectedKey)).toEqual(BYTES_B);

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts).toHaveLength(1);
    const row = db.inserts[0].row as { user_id: string; r2_key: string; content_sha256: string };
    expect(row.user_id).toBe('alice');
    expect(row.r2_key).toBe(expectedKey);
    expect(row.content_sha256).toBe(hash);
  });
});

describe('POST /v1/upload — device-grant (PendingCrew) path', () => {
  it('attributes the attachment row to the grant\'s granted_by_user_id', async () => {
    const token = 'pdg_upload_test_token';
    const grant = await makeDeviceGrant(token, 'owner-user', ['subject:read', 'crew:read', 'crew:write']);
    const env = makeFakeEnv(makeFakeDb({
      attachments: [],
      billing_config: [],
      subject_device_grants: [grant],
    }));
    const r2 = makeR2Mock();
    bindR2(env as unknown as Record<string, unknown>, r2);

    const r = await post(env, 'unused', {
      file: { file: BYTES_B, name: 'crew.png', type: 'image/png' },
    }, { bearer: token });
    expect(r.status).toBe(200);

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts).toHaveLength(1);
    // Owner is the user who granted PendingCrew, not the subject/device.
    expect((db.inserts[0].row as { user_id: string }).user_id).toBe('owner-user');
  });

  it('rejects a device grant lacking crew:write with 403', async () => {
    const token = 'pdg_no_crew_write';
    const grant = await makeDeviceGrant(token, 'owner-user', ['subject:read', 'crew:read']);
    const env = makeFakeEnv(makeFakeDb({
      attachments: [],
      billing_config: [],
      subject_device_grants: [grant],
    }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());

    const r = await post(env, 'unused', {
      file: { file: BYTES_A, name: 'a.png', type: 'image/png' },
    }, { bearer: token });
    expect(r.status).toBe(403);
  });
});

describe('GET /v1/uploads/:id — strict access scope', () => {
  it('serves bytes to the uploader', async () => {
    const attRow: Row = {
      id: 'att-1',
      user_id: 'alice',
      r2_key: 'blobs/h.png',
      mime_type: 'image/png',
    };
    const env = makeFakeEnv(makeFakeDb({ attachments: [attRow], messages: [], conversation_participants: [] }));
    const r2 = makeR2Mock();
    r2.store.set('blobs/h.png', BYTES_A);
    bindR2(env as unknown as Record<string, unknown>, r2);

    const app = new Hono<AppBindings>();
    app.route('/v1/uploads', uploadRoutes);
    const res = await app.request('/v1/uploads/att-1', { headers: { 'x-test-user-id': 'alice' } }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toBe('image/png');
  });

  it('serves bytes to a participant of a conv containing a non-deleted msg referencing the id', async () => {
    const attRow: Row = { id: 'att-1', user_id: 'alice', r2_key: 'blobs/h.png', mime_type: 'image/png' };
    const msgRow: Row = {
      conversation_id: 'conv-1',
      status: 'done',
      attachments: { ids: ['att-1'] },
    };
    const participantRow: Row = {
      conversation_id: 'conv-1',
      participant_type: 'user',
      participant_id: 'bob',
    };
    const env = makeFakeEnv(makeFakeDb({
      attachments: [attRow],
      messages: [msgRow],
      conversation_participants: [participantRow],
    }));
    const r2 = makeR2Mock();
    r2.store.set('blobs/h.png', BYTES_A);
    bindR2(env as unknown as Record<string, unknown>, r2);

    const app = new Hono<AppBindings>();
    app.route('/v1/uploads', uploadRoutes);
    const res = await app.request('/v1/uploads/att-1', { headers: { 'x-test-user-id': 'bob' } }, env);
    expect(res.status).toBe(200);
  });

  it('returns 404 for a non-uploader, non-participant', async () => {
    const attRow: Row = { id: 'att-1', user_id: 'alice', r2_key: 'blobs/h.png', mime_type: 'image/png' };
    const env = makeFakeEnv(makeFakeDb({ attachments: [attRow], messages: [], conversation_participants: [] }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());

    const r = await get(env, 'eve', 'att-1');
    expect(r.status).toBe(404);
    expect((r.body.error as { code?: string }).code).toBe('not_found');
  });

  it('returns 404 for a participant whose only reference is a recalled (status=deleted) msg', async () => {
    // bob was a participant of conv-1, and the only msg referencing att-1
    // is now status='deleted' (recalled). access must be revoked.
    const attRow: Row = { id: 'att-1', user_id: 'alice', r2_key: 'blobs/h.png', mime_type: 'image/png' };
    const msgRow: Row = {
      conversation_id: 'conv-1',
      status: 'deleted',
      attachments: { ids: ['att-1'] },
    };
    const participantRow: Row = {
      conversation_id: 'conv-1',
      participant_type: 'user',
      participant_id: 'bob',
    };
    const env = makeFakeEnv(makeFakeDb({
      attachments: [attRow],
      messages: [msgRow],
      conversation_participants: [participantRow],
    }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock());

    const r = await get(env, 'bob', 'att-1');
    expect(r.status).toBe(404);
  });

  it('returns 410 attachment_object_missing when DB row exists but R2 object is gone', async () => {
    const attRow: Row = { id: 'att-1', user_id: 'alice', r2_key: 'blobs/missing.png', mime_type: 'image/png' };
    const env = makeFakeEnv(makeFakeDb({ attachments: [attRow], messages: [], conversation_participants: [] }));
    bindR2(env as unknown as Record<string, unknown>, makeR2Mock()); // empty store

    const r = await get(env, 'alice', 'att-1');
    expect(r.status).toBe(410);
    expect((r.body.error as { code?: string }).code).toBe('attachment_object_missing');
  });
});
