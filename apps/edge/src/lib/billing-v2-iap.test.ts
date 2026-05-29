import { describe, expect, it } from 'vitest';
import { decodeAppleJws, verifyAppleJws } from './billing-v2-iap';
import type { Env } from '../types';

// JWS hand-crafted: header={alg:'none'}, payload={transactionId:'demo'},
// signature='sig' — used only to exercise the decode path; not verifiable.
const FAKE_JWS = 'eyJhbGciOiJub25lIn0.eyJ0cmFuc2FjdGlvbklkIjoiZGVtbyJ9.sig';

describe('decodeAppleJws', () => {
  it('returns header + payload for a well-formed JWS', () => {
    const out = decodeAppleJws<{ transactionId: string }>(FAKE_JWS);
    expect(out).not.toBeNull();
    expect(out!.payload.transactionId).toBe('demo');
  });

  it('returns null for malformed (wrong segment count)', () => {
    expect(decodeAppleJws('a.b')).toBeNull();
    expect(decodeAppleJws('a.b.c.d')).toBeNull();
  });

  it('returns null when a segment is not JSON', () => {
    expect(decodeAppleJws('YWJj.YWJj.sig')).toBeNull();
  });
});

describe('verifyAppleJws', () => {
  it('fails closed pre-launch — must throw not-implemented', async () => {
    const env = {} as Env;
    await expect(verifyAppleJws(FAKE_JWS, env)).rejects.toThrow(
      'apple_jws_verification_not_implemented',
    );
  });
});
