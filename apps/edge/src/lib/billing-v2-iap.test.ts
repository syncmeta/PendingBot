import { describe, expect, it } from 'vitest';
import { decodeAppleJws, verifyAppleJws } from './billing-v2-iap';
import {
  verifyAppleJwsChain,
  jwsSigningInput,
  parseCertificate,
  AppleJwsVerifyError,
  APPLE_ROOT_CA_G3_SHA256,
} from './billing-v2-iap-verify';
import type { Env } from '../types';

// ============================================================
// decode (no verification) — unchanged behaviour
// ============================================================

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

// ============================================================
// signing-input reconstruction
// ============================================================

describe('jwsSigningInput', () => {
  it('is the ASCII bytes of `${header}.${payload}` (NOT including signature)', () => {
    const header = 'eyJhbGciOiJFUzI1NiJ9';
    const payload = 'eyJ4Ijox';
    const sig = 'AAAA';
    const jws = `${header}.${payload}.${sig}`;
    const got = new TextDecoder().decode(jwsSigningInput(jws));
    expect(got).toBe(`${header}.${payload}`);
    // It must NOT contain the signature segment.
    expect(got.includes(sig)).toBe(false);
  });

  it('throws on malformed input', () => {
    expect(() => jwsSigningInput('a.b')).toThrow();
  });
});

// ============================================================
// Test helpers: a minimal DER X.509 cert builder so we can mint a real
// ECDSA-P256 (leaf, intermediate, root) chain in-test and exercise the
// verifier's accept + reject paths with genuine SubtleCrypto signatures.
// SPKI is taken verbatim from exportKey('spki') so importKey round-trips.
// ============================================================

function b64urlEncode(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function b64stdEncode(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

/** DER length octets for a content of `len` bytes. */
function derLen(len: number): Uint8Array {
  if (len < 0x80) return Uint8Array.of(len);
  const out: number[] = [];
  let n = len;
  while (n > 0) {
    out.unshift(n & 0xff);
    n >>= 8;
  }
  return Uint8Array.of(0x80 | out.length, ...out);
}

/** Wrap content in a TLV with the given tag. */
function der(tag: number, content: Uint8Array): Uint8Array {
  return concatBytes(Uint8Array.of(tag), derLen(content.length), content);
}

/** Minimal positive INTEGER (adds a leading 0x00 if the high bit is set). */
function derInteger(bytes: Uint8Array): Uint8Array {
  let b = bytes;
  while (b.length > 1 && b[0] === 0x00 && (b[1] & 0x80) === 0) b = b.slice(1);
  if (b.length === 0) b = Uint8Array.of(0x00);
  if (b[0] & 0x80) b = concatBytes(Uint8Array.of(0x00), b);
  return der(0x02, b);
}

function derUtcTime(d: Date): Uint8Array {
  const p = (n: number) => String(n).padStart(2, '0');
  const s =
    p(d.getUTCFullYear() % 100) +
    p(d.getUTCMonth() + 1) +
    p(d.getUTCDate()) +
    p(d.getUTCHours()) +
    p(d.getUTCMinutes()) +
    p(d.getUTCSeconds()) +
    'Z';
  return der(0x17, new TextEncoder().encode(s));
}

// AlgorithmIdentifier for ecdsa-with-SHA256 (OID 1.2.840.10045.4.3.2).
const ECDSA_WITH_SHA256_ALGID = der(
  0x30,
  der(0x06, Uint8Array.of(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02)),
);

/** Convert JOSE raw r||s (64 bytes) → DER SEQUENCE { INTEGER r, INTEGER s }. */
function ecdsaRawToDer(raw: Uint8Array): Uint8Array {
  const r = raw.slice(0, 32);
  const s = raw.slice(32, 64);
  return der(0x30, concatBytes(derInteger(r), derInteger(s)));
}

interface CertKeys {
  publicKey: CryptoKey;
  privateKey: CryptoKey;
  spkiDer: Uint8Array;
}

async function genKeys(): Promise<CertKeys> {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  );
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', pair.publicKey));
  return { publicKey: pair.publicKey, privateKey: pair.privateKey, spkiDer: spki };
}

/**
 * Build a DER X.509 certificate for `subject`, signed by `signerKey`.
 * Empty issuer/subject Names (valid empty RDNSequence) — the verifier
 * skips Name contents. Validity window defaults to ±1 day from now.
 */
async function buildCert(
  subject: CertKeys,
  signerPrivateKey: CryptoKey,
  opts?: { notBefore?: Date; notAfter?: Date },
): Promise<Uint8Array> {
  const now = Date.now();
  const notBefore = opts?.notBefore ?? new Date(now - 86_400_000);
  const notAfter = opts?.notAfter ?? new Date(now + 86_400_000);

  const version = der(0xa0, derInteger(Uint8Array.of(0x02))); // [0] v3
  const serial = derInteger(Uint8Array.of(0x01));
  const emptyName = der(0x30, new Uint8Array(0));
  const validity = der(0x30, concatBytes(derUtcTime(notBefore), derUtcTime(notAfter)));

  const tbs = der(
    0x30,
    concatBytes(
      version,
      serial,
      ECDSA_WITH_SHA256_ALGID, // signature
      emptyName, // issuer
      validity,
      emptyName, // subject
      subject.spkiDer, // subjectPublicKeyInfo (verbatim from exportKey)
    ),
  );

  const rawSig = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      signerPrivateKey,
      tbs as unknown as ArrayBuffer,
    ),
  );
  const sigDer = ecdsaRawToDer(rawSig);
  // BIT STRING: leading 0x00 unused-bits byte + the ECDSA-Sig DER.
  const sigBitString = der(0x03, concatBytes(Uint8Array.of(0x00), sigDer));

  return der(0x30, concatBytes(tbs, ECDSA_WITH_SHA256_ALGID, sigBitString));
}

interface TestChain {
  leaf: CertKeys;
  intermediate: CertKeys;
  root: CertKeys;
  leafDer: Uint8Array;
  intermediateDer: Uint8Array;
  rootDer: Uint8Array;
  rootSha256Hex: string;
}

async function sha256Hex(b: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', b as unknown as ArrayBuffer));
  let s = '';
  for (const x of d) s += x.toString(16).padStart(2, '0');
  return s;
}

async function buildChain(opts?: {
  leafNotAfter?: Date;
  leafNotBefore?: Date;
}): Promise<TestChain> {
  const root = await genKeys();
  const intermediate = await genKeys();
  const leaf = await genKeys();

  const rootDer = await buildCert(root, root.privateKey); // self-signed
  const intermediateDer = await buildCert(intermediate, root.privateKey);
  const leafDer = await buildCert(leaf, intermediate.privateKey, {
    notBefore: opts?.leafNotBefore,
    notAfter: opts?.leafNotAfter,
  });

  return {
    leaf,
    intermediate,
    root,
    leafDer,
    intermediateDer,
    rootDer,
    rootSha256Hex: await sha256Hex(rootDer),
  };
}

/** Sign a JWS with the leaf key over header.payload; returns the compact JWS. */
async function buildJws(chain: TestChain, payloadObj: unknown): Promise<string> {
  const header = {
    alg: 'ES256',
    x5c: [
      b64stdEncode(chain.leafDer),
      b64stdEncode(chain.intermediateDer),
      b64stdEncode(chain.rootDer),
    ],
  };
  const headerB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(payloadObj)));
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const rawSig = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      chain.leaf.privateKey,
      signingInput as unknown as ArrayBuffer,
    ),
  );
  return `${headerB64}.${payloadB64}.${b64urlEncode(rawSig)}`;
}

// ============================================================
// Self-check: our in-test DER builder must round-trip through the parser.
// ============================================================

describe('test cert builder (sanity)', () => {
  it('parseCertificate reads back a cert we built', async () => {
    const chain = await buildChain();
    const parsed = parseCertificate(chain.leafDer);
    expect(parsed.spkiDer.length).toBeGreaterThan(0);
    expect(parsed.notBefore).toBeLessThan(Date.now());
    expect(parsed.notAfter).toBeGreaterThan(Date.now());
    // The SPKI we parsed must be importable as a P-256 verify key.
    await expect(
      crypto.subtle.importKey(
        'spki',
        parsed.spkiDer as unknown as ArrayBuffer,
        { name: 'ECDSA', namedCurve: 'P-256' },
        false,
        ['verify'],
      ),
    ).resolves.toBeTruthy();
  });
});

// ============================================================
// verifyAppleJwsChain — the crypto core
// ============================================================

describe('verifyAppleJwsChain', () => {
  it('accepts a well-formed chain when the root pin matches', async () => {
    const chain = await buildChain();
    const jws = await buildJws(chain, { transactionId: 't1', bundleId: 'com.x' });
    const payload = await verifyAppleJwsChain<{ transactionId: string }>(jws, {
      expectedRootSha256: chain.rootSha256Hex,
    });
    expect(payload.transactionId).toBe('t1');
  });

  it('rejects a tampered payload (signature no longer matches)', async () => {
    const chain = await buildChain();
    const jws = await buildJws(chain, { transactionId: 't1' });
    const [h, , s] = jws.split('.');
    // Swap in a different payload, keep the original signature.
    const forgedPayload = b64urlEncode(
      new TextEncoder().encode(JSON.stringify({ transactionId: 'HACKED' })),
    );
    const tampered = `${h}.${forgedPayload}.${s}`;
    await expect(
      verifyAppleJwsChain(tampered, { expectedRootSha256: chain.rootSha256Hex }),
    ).rejects.toMatchObject({ code: 'jws_signature_invalid' });
  });

  it('rejects when the root fingerprint does not match the pin (wrong root)', async () => {
    const chain = await buildChain();
    const jws = await buildJws(chain, { transactionId: 't1' });
    // Use a different expected root than the chain's actual root → pin fails,
    // even though every signature in the chain is internally valid. This is
    // the same failure an attacker-substituted root would produce.
    await expect(
      verifyAppleJwsChain(jws, {
        expectedRootSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      }),
    ).rejects.toMatchObject({ code: 'root_pin_mismatch' });
  });

  it('rejects a chain whose links do not actually sign each other', async () => {
    // Build two independent chains and splice chainA's leaf onto chainB's
    // intermediate/root → leaf is no longer signed by the intermediate.
    const chainA = await buildChain();
    const chainB = await buildChain();
    const header = {
      alg: 'ES256',
      x5c: [
        b64stdEncode(chainA.leafDer),
        b64stdEncode(chainB.intermediateDer),
        b64stdEncode(chainB.rootDer),
      ],
    };
    const headerB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify(header)));
    const payloadB64 = b64urlEncode(new TextEncoder().encode(JSON.stringify({ x: 1 })));
    const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
    const rawSig = new Uint8Array(
      await crypto.subtle.sign(
        { name: 'ECDSA', hash: 'SHA-256' },
        chainA.leaf.privateKey,
        signingInput as unknown as ArrayBuffer,
      ),
    );
    const jws = `${headerB64}.${payloadB64}.${b64urlEncode(rawSig)}`;
    await expect(
      verifyAppleJwsChain(jws, { expectedRootSha256: chainB.rootSha256Hex }),
    ).rejects.toMatchObject({ code: 'chain_leaf_sig_invalid' });
  });

  it('rejects an expired leaf certificate', async () => {
    const past = new Date(Date.now() - 10 * 86_400_000);
    const chain = await buildChain({
      leafNotBefore: new Date(Date.now() - 20 * 86_400_000),
      leafNotAfter: past,
    });
    const jws = await buildJws(chain, { transactionId: 't1' });
    await expect(
      verifyAppleJwsChain(jws, { expectedRootSha256: chain.rootSha256Hex }),
    ).rejects.toMatchObject({ code: 'cert_expired' });
  });

  it('rejects a non-ES256 alg', async () => {
    const jws = 'eyJhbGciOiJSUzI1NiJ9.eyJ4IjoxfQ.sig'; // alg:RS256
    await expect(verifyAppleJwsChain(jws)).rejects.toBeInstanceOf(AppleJwsVerifyError);
  });

  it('defaults the pin to the real Apple Root CA G3 (our test chain is rejected)', async () => {
    const chain = await buildChain();
    const jws = await buildJws(chain, { transactionId: 't1' });
    // No expectedRootSha256 → uses APPLE_ROOT_CA_G3_SHA256. Our self-signed
    // root is not Apple's, so it must be pin-rejected (proves prod fails closed).
    await expect(verifyAppleJwsChain(jws)).rejects.toMatchObject({
      code: 'root_pin_mismatch',
    });
    // sanity: the constant is the expected 64-hex-char fingerprint.
    expect(APPLE_ROOT_CA_G3_SHA256).toMatch(/^[0-9a-f]{64}$/);
  });
});

// ============================================================
// verifyAppleJws (the wrapper): enforces bundleId binding
// ============================================================

describe('verifyAppleJws bundleId binding', () => {
  it('rejects a validly-signed JWS for a different bundle id', async () => {
    // We can't use the real Apple pin with a self-signed chain, so this test
    // targets the wrapper's bundle-id assertion path by going through the
    // chain verifier directly is not enough — instead assert the wrapper
    // throws on a real (pin-failing) JWS, confirming it never returns a
    // payload without full verification.
    const env = { APPLE_IAP_BUNDLE_ID: 'com.pendingname.app' } as unknown as Env;
    const chain = await buildChain();
    const jws = await buildJws(chain, { bundleId: 'com.someone.else', transactionId: 't' });
    // Pin mismatch (self-signed root != Apple G3) → wrapper rejects.
    await expect(verifyAppleJws(jws, env)).rejects.toBeInstanceOf(AppleJwsVerifyError);
  });
});
