import { describe, expect, it } from 'vitest';
import {
  DEFAULT_ATTACHMENT_QUOTA_BYTES,
  MAX_UPLOAD_BYTES,
  classifyAttachment,
  extForMime,
  isPdfMime,
  isSupportedImageMime,
  r2KeyFor,
  r2KeyForHash,
  sha256Hex,
} from './attachments';

// Pure helpers that gate upload flow:
//   • sha256Hex feeds the (user_id, content_sha256) UNIQUE dedup index
//     in migration 20260512052048 — wrong hash = silent dedup miss or
//     spurious collisions, so we pin known vectors.
//   • isSupportedImageMime / extForMime decide which inbound files we
//     accept; the 415 rejection in routes/upload depends on this.
//   • r2KeyFor produces the yyyy-mm/<uuid>.<ext> shape the orphan-sweep
//     cron globs against — drift here would silently break cleanup.

describe('sha256Hex', () => {
  it('matches the canonical empty-string vector', async () => {
    const h = await sha256Hex(new Uint8Array());
    expect(h).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });

  it('matches the canonical "abc" vector', async () => {
    const h = await sha256Hex(new TextEncoder().encode('abc'));
    expect(h).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  it('returns 64 lowercase hex chars regardless of input size', async () => {
    const h = await sha256Hex(new Uint8Array([0x01, 0x02, 0x03, 0xff]));
    expect(h).toMatch(/^[0-9a-f]{64}$/);
  });

  it('is deterministic across calls', async () => {
    const bytes = new TextEncoder().encode('pendingbot');
    const a = await sha256Hex(bytes);
    const b = await sha256Hex(bytes);
    expect(a).toBe(b);
  });
});

describe('isSupportedImageMime', () => {
  it.each(['image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/webp'])(
    'accepts %s',
    (mime) => {
      expect(isSupportedImageMime(mime)).toBe(true);
    },
  );

  it('is case-insensitive', () => {
    expect(isSupportedImageMime('Image/PNG')).toBe(true);
    expect(isSupportedImageMime('IMAGE/JPEG')).toBe(true);
  });

  it.each(['image/heic', 'image/svg+xml', 'application/pdf', 'video/mp4', '', 'image/'])(
    'rejects %s',
    (mime) => {
      expect(isSupportedImageMime(mime)).toBe(false);
    },
  );
});

describe('extForMime', () => {
  it('maps known mimes to short extensions', () => {
    expect(extForMime('image/jpeg')).toBe('jpg');
    expect(extForMime('image/jpg')).toBe('jpg');
    expect(extForMime('image/png')).toBe('png');
    expect(extForMime('image/gif')).toBe('gif');
    expect(extForMime('image/webp')).toBe('webp');
  });

  it('falls back to "bin" for unknown mimes', () => {
    // The orphan sweep matches `${yyyy-mm}/*` regardless of ext, so a
    // "bin" key still gets reaped — but inbound mime is gate-checked
    // before r2KeyFor sees it, so this branch is defense-in-depth.
    expect(extForMime('application/octet-stream')).toBe('bin');
  });
});

describe('r2KeyFor', () => {
  it('produces yyyy-mm/<uuid>.<ext> shape', () => {
    const key = r2KeyFor('abc-123', 'image/png', Date.UTC(2026, 4, 12, 10, 0, 0));
    expect(key).toBe('2026-05/abc-123.png');
  });

  it('pads single-digit months to 2 chars', () => {
    const key = r2KeyFor('id', 'image/jpeg', Date.UTC(2026, 0, 5));
    expect(key).toBe('2026-01/id.jpg');
  });

  it('uses UTC, not local time', () => {
    // 2026-01-01 00:00 UTC — even if the runner is in UTC+8 (where
    // the local clock reads 2026-01-01 08:00) the bucket must stay
    // 2026-01, not slip into the previous year.
    const key = r2KeyFor('id', 'image/png', Date.UTC(2026, 0, 1, 0, 0, 0));
    expect(key.startsWith('2026-01/')).toBe(true);
  });
});

describe('r2KeyForHash', () => {
  it('produces blobs/<hash>.<ext> shape', () => {
    expect(
      r2KeyForHash(
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'image/png',
      ),
    ).toBe('blobs/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.png');
  });

  it('is deterministic — two callers with the same bytes get the same key', () => {
    // This is the whole point: cross-user dedup hinges on the function
    // being a pure mapping of (hash, mime) → key. Any drift (time-based
    // prefix, random salt, user id) would break the dedup.
    const a = r2KeyForHash('abc123', 'image/jpeg');
    const b = r2KeyForHash('abc123', 'image/jpeg');
    expect(a).toBe(b);
  });

  it('falls back to "bin" ext for unsupported mimes', () => {
    expect(r2KeyForHash('h', 'application/octet-stream')).toBe('blobs/h.bin');
  });
});

describe('isPdfMime', () => {
  it('matches application/pdf, including a charset suffix', () => {
    expect(isPdfMime('application/pdf')).toBe(true);
    expect(isPdfMime('APPLICATION/PDF')).toBe(true);
    expect(isPdfMime('application/pdf; charset=binary')).toBe(true);
    expect(isPdfMime('image/png')).toBe(false);
    expect(isPdfMime('application/zip')).toBe(false);
  });
});

describe('classifyAttachment', () => {
  it('routes images / pdf / other to the right kind', () => {
    expect(classifyAttachment('image/png')).toBe('image');
    expect(classifyAttachment('image/jpeg')).toBe('image');
    expect(classifyAttachment('application/pdf')).toBe('pdf');
    expect(classifyAttachment('application/zip')).toBe('file');
    expect(classifyAttachment('text/x-python')).toBe('file');
    expect(classifyAttachment('audio/mpeg')).toBe('file');
  });
});

describe('exported constants', () => {
  it('MAX_UPLOAD_BYTES is 25 MiB', () => {
    expect(MAX_UPLOAD_BYTES).toBe(25 * 1024 * 1024);
  });

  it('DEFAULT_ATTACHMENT_QUOTA_BYTES matches the 1 GiB migration seed', () => {
    // billing_config.default_attachment_quota_bytes seed in migration
    // 20260512043115 must match this fallback, or a fresh prod with no
    // seed row will diverge from a seeded one.
    expect(DEFAULT_ATTACHMENT_QUOTA_BYTES).toBe(1 * 1024 * 1024 * 1024);
  });
});
