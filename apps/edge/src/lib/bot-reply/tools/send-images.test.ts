import { describe, expect, it } from 'vitest';
import { decodeDataUrl, isBlockedHost, sniffImageMime } from './send-images';

// Real magic bytes for the four allowed image types — these are the
// signatures we'll see in actual payloads, so the sniff test pins them
// rather than recycling the constants from the implementation.
const PNG_MAGIC = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00]);
const JPEG_MAGIC = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]);
const WEBP_MAGIC = new Uint8Array([
  0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50,
]);
const GIF89A_MAGIC = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00]);
const GIF87A_MAGIC = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x37, 0x61, 0x01, 0x00]);

function bytesToBase64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

describe('sniffImageMime', () => {
  it('recognises PNG / JPEG / WebP / GIF87a / GIF89a magic bytes', () => {
    expect(sniffImageMime(PNG_MAGIC)).toBe('image/png');
    expect(sniffImageMime(JPEG_MAGIC)).toBe('image/jpeg');
    expect(sniffImageMime(WEBP_MAGIC)).toBe('image/webp');
    expect(sniffImageMime(GIF87A_MAGIC)).toBe('image/gif');
    expect(sniffImageMime(GIF89A_MAGIC)).toBe('image/gif');
  });

  it('returns null for unknown / short payloads', () => {
    expect(sniffImageMime(new Uint8Array([0x00]))).toBeNull();
    // RIFF prefix without WEBP fourcc — must NOT misfire as webp
    expect(sniffImageMime(new Uint8Array([
      0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
      0x57, 0x41, 0x56, 0x45, // WAVE
    ]))).toBeNull();
    // GIF prefix but with the wrong dialect byte
    expect(sniffImageMime(new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x30, 0x61, 0x00]))).toBeNull();
  });
});

describe('isBlockedHost', () => {
  it('blocks IPv4 private / loopback / link-local / metadata / multicast', () => {
    expect(isBlockedHost('127.0.0.1')).toBe(true);
    expect(isBlockedHost('10.0.0.1')).toBe(true);
    expect(isBlockedHost('172.16.0.1')).toBe(true);
    expect(isBlockedHost('172.31.255.254')).toBe(true);
    expect(isBlockedHost('192.168.1.1')).toBe(true);
    expect(isBlockedHost('169.254.169.254')).toBe(true);   // AWS/GCP metadata
    expect(isBlockedHost('0.0.0.0')).toBe(true);
    expect(isBlockedHost('224.0.0.1')).toBe(true);          // multicast
    expect(isBlockedHost('255.255.255.255')).toBe(true);
  });

  it('blocks localhost names and metadata hostname', () => {
    expect(isBlockedHost('localhost')).toBe(true);
    expect(isBlockedHost('foo.localhost')).toBe(true);
    expect(isBlockedHost('metadata.google.internal')).toBe(true);
  });

  it('blocks IPv6 loopback / link-local / ULA', () => {
    expect(isBlockedHost('::1')).toBe(true);
    expect(isBlockedHost('[::1]')).toBe(true);
    expect(isBlockedHost('fe80::1')).toBe(true);
    expect(isBlockedHost('fc00::1')).toBe(true);
    expect(isBlockedHost('fd12:3456::1')).toBe(true);
  });

  it('lets public IPv4 / DNS names through', () => {
    expect(isBlockedHost('1.1.1.1')).toBe(false);
    expect(isBlockedHost('172.32.0.1')).toBe(false);        // just outside 172.16-31
    expect(isBlockedHost('192.169.0.1')).toBe(false);
    expect(isBlockedHost('example.com')).toBe(false);
    expect(isBlockedHost('cdn.r2.dev')).toBe(false);
  });
});

describe('decodeDataUrl', () => {
  it('decodes a valid PNG data URL', () => {
    const dataUrl = `data:image/png;base64,${bytesToBase64(PNG_MAGIC)}`;
    const out = decodeDataUrl(dataUrl);
    expect(out.mime).toBe('image/png');
    expect(out.bytes.length).toBe(PNG_MAGIC.length);
  });

  it('normalises image/jpg → image/jpeg via the alias map', () => {
    const dataUrl = `data:image/jpg;base64,${bytesToBase64(JPEG_MAGIC)}`;
    const out = decodeDataUrl(dataUrl);
    expect(out.mime).toBe('image/jpeg');
  });

  it('overrides a wrong claimed MIME with the magic-byte sniff', () => {
    // Claims PNG but the payload is actually JPEG — sniff wins so we
    // don't end up writing a JPEG body under content-type image/png in
    // R2 (would still play OK in browsers but trips strict CDN paths).
    const dataUrl = `data:image/png;base64,${bytesToBase64(JPEG_MAGIC)}`;
    const out = decodeDataUrl(dataUrl);
    expect(out.mime).toBe('image/jpeg');
  });

  it('rejects unsupported MIME', () => {
    expect(() => decodeDataUrl('data:application/pdf;base64,JVBERi0=')).toThrow(/unsupported/);
  });

  it('rejects non-base64 data URLs', () => {
    expect(() => decodeDataUrl('data:image/png,raw-bytes')).toThrow(/base64/);
  });

  it('rejects malformed base64 payload', () => {
    expect(() => decodeDataUrl('data:image/png;base64,!!!not_base64!!!')).toThrow();
  });
});
