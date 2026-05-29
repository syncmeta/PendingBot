import { beforeAll, describe, expect, it } from 'vitest';
import { verifyLemonSqueezySignature } from './billing-v2-lemon';

const KNOWN_BODY = '{"hello":"world"}';
const SECRET = 'test_secret';
// Computed at test startup via WebCrypto so the fixture matches whatever
// SHA-256 / HMAC the host platform uses — no manual openssl dependency.
let KNOWN_SIG = '';

async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)),
  );
  return Array.from(sig)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

beforeAll(async () => {
  KNOWN_SIG = await hmacHex(SECRET, KNOWN_BODY);
});

describe('verifyLemonSqueezySignature', () => {
  it('verifies a known good HMAC-SHA256 hex signature', async () => {
    const ok = await verifyLemonSqueezySignature(
      new TextEncoder().encode(KNOWN_BODY),
      KNOWN_SIG,
      SECRET,
    );
    expect(ok).toBe(true);
  });

  it('rejects a tampered body', async () => {
    const ok = await verifyLemonSqueezySignature(
      new TextEncoder().encode('{"hello":"WORLD"}'),
      KNOWN_SIG,
      SECRET,
    );
    expect(ok).toBe(false);
  });

  it('rejects a tampered signature', async () => {
    const flipped = KNOWN_SIG.slice(0, -1) + (KNOWN_SIG.endsWith('a') ? 'b' : 'a');
    const ok = await verifyLemonSqueezySignature(
      new TextEncoder().encode(KNOWN_BODY),
      flipped,
      SECRET,
    );
    expect(ok).toBe(false);
  });

  it('rejects wrong-secret signature', async () => {
    const ok = await verifyLemonSqueezySignature(
      new TextEncoder().encode(KNOWN_BODY),
      KNOWN_SIG,
      'other_secret',
    );
    expect(ok).toBe(false);
  });

  it('rejects malformed hex signature', async () => {
    const ok = await verifyLemonSqueezySignature(
      new TextEncoder().encode(KNOWN_BODY),
      'not-hex',
      SECRET,
    );
    expect(ok).toBe(false);
  });

  it('rejects empty signature or secret (early bail)', async () => {
    expect(
      await verifyLemonSqueezySignature(new TextEncoder().encode(KNOWN_BODY), '', SECRET),
    ).toBe(false);
    expect(
      await verifyLemonSqueezySignature(new TextEncoder().encode(KNOWN_BODY), KNOWN_SIG, ''),
    ).toBe(false);
  });
});
