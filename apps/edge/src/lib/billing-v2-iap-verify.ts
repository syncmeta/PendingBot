// Apple App Store Server API JWS (x5c) verification — zero-dependency
// implementation for the Cloudflare Workers runtime (WebCrypto SubtleCrypto,
// no Node crypto, no X.509 library).
//
// Why hand-rolled DER parsing instead of @peculiar/x509: the repo keeps a
// deliberately small dependency surface, and the only things we need from a
// full X.509 stack are (1) the leaf's SPKI public key, (2) each cert's
// validity window, (3) the parent's SPKI to verify the next link's
// signature, and (4) the root DER bytes to SHA-256-pin. Apple's App Store
// Server certificates are all ECDSA P-256 (ES256), which makes the ASN.1 we
// must understand small and fixed. We extract exactly those four things and
// nothing else. Any structural deviation throws loudly rather than silently
// accepting — the correct failure mode for a payment-authenticity gate.
//
// Apple Root CA G3 is the trust anchor for the App Store Server API JWS.
// We pin its SHA-256(DER) fingerprint as a constant (APPLE_ROOT_CA_G3_SHA256)
// so a forged chain with an attacker-controlled root is rejected even if
// every signature in it is internally consistent.
// Reference: https://www.apple.com/certificateauthority/

// ============================================================
// base64 / bytes helpers
// ============================================================

/** Standard base64 (NOT base64url) → bytes. x5c entries are standard base64 DER. */
function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** base64url (no padding) → bytes. JWS header/payload/signature segments. */
function base64UrlToBytes(input: string): Uint8Array {
  const padded = input.replace(/-/g, '+').replace(/_/g, '/');
  const pad = padded.length % 4;
  const b64 = pad === 0 ? padded : padded + '='.repeat(4 - pad);
  return base64ToBytes(b64);
}

function bytesToHex(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, '0');
  return s;
}

function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) throw new Error('bad_hex');
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** Constant-time-ish equality for fixed-length digests. */
function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ============================================================
// Minimal DER / ASN.1 reader
// ============================================================
//
// One TLV node. `start` is the offset of the tag byte; `contentStart` the
// first content byte; `end` one past the last content byte. `headerLen` =
// contentStart - start.

interface Der {
  tag: number;
  start: number;
  contentStart: number;
  end: number;
}

/** Read the single TLV starting at `pos` within `buf` (bounded by `limit`). */
function readDer(buf: Uint8Array, pos: number, limit: number): Der {
  if (pos + 2 > limit) throw new Error('der_truncated_header');
  const tag = buf[pos];
  let p = pos + 1;
  let len = buf[p++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) throw new Error('der_bad_length');
    len = 0;
    for (let i = 0; i < n; i++) {
      if (p >= limit) throw new Error('der_truncated_length');
      len = (len << 8) | buf[p++];
    }
  }
  const contentStart = p;
  const end = contentStart + len;
  if (end > limit) throw new Error('der_content_overflow');
  return { tag, start: pos, contentStart, end };
}

/** Read every TLV in [contentStart, end) sequentially (children of a SEQUENCE). */
function readChildren(buf: Uint8Array, parent: Der): Der[] {
  const out: Der[] = [];
  let pos = parent.contentStart;
  while (pos < parent.end) {
    const node = readDer(buf, pos, parent.end);
    out.push(node);
    pos = node.end;
  }
  return out;
}

function slice(buf: Uint8Array, node: Der): Uint8Array {
  // Whole TLV including its tag + length header.
  return buf.slice(node.start, node.end);
}

// ============================================================
// X.509 parse (only the fields we need)
// ============================================================

export interface ParsedCert {
  /** The TBSCertificate TLV bytes, including header — this is what's signed. */
  tbsBytes: Uint8Array;
  /** SubjectPublicKeyInfo as DER (importKey 'spki' input). */
  spkiDer: Uint8Array;
  /** The cert's own ECDSA signature, JOSE raw r||s (64 bytes for P-256). */
  signatureRaw: Uint8Array;
  notBefore: number; // ms epoch
  notAfter: number; // ms epoch
  /** Full cert DER, for root pinning. */
  der: Uint8Array;
}

function parseDerTime(buf: Uint8Array, node: Der): number {
  // tag 0x17 = UTCTime (YYMMDDHHMMSSZ), 0x18 = GeneralizedTime (YYYYMMDDHHMMSSZ)
  const s = new TextDecoder().decode(buf.slice(node.contentStart, node.end));
  let year: number;
  let rest: string;
  if (node.tag === 0x17) {
    const yy = parseInt(s.slice(0, 2), 10);
    year = yy >= 50 ? 1900 + yy : 2000 + yy; // RFC 5280 sliding window
    rest = s.slice(2);
  } else if (node.tag === 0x18) {
    year = parseInt(s.slice(0, 4), 10);
    rest = s.slice(4);
  } else {
    throw new Error('der_bad_time_tag');
  }
  const mo = parseInt(rest.slice(0, 2), 10);
  const da = parseInt(rest.slice(2, 4), 10);
  const ho = parseInt(rest.slice(4, 6), 10);
  const mi = parseInt(rest.slice(6, 8), 10);
  const se = parseInt(rest.slice(8, 10), 10);
  if ([mo, da, ho, mi, se].some((n) => Number.isNaN(n)) || Number.isNaN(year)) {
    throw new Error('der_bad_time');
  }
  return Date.UTC(year, mo - 1, da, ho, mi, se);
}

/**
 * Convert an ECDSA signature from X.509 DER form (SEQUENCE { INTEGER r,
 * INTEGER s }) to JOSE raw form (r||s, each left-padded to `intLen`).
 * SubtleCrypto ECDSA verify wants the raw form.
 */
function ecdsaDerToRaw(sigDer: Uint8Array, intLen = 32): Uint8Array {
  const seq = readDer(sigDer, 0, sigDer.length);
  if (seq.tag !== 0x30) throw new Error('der_sig_not_sequence');
  const ints = readChildren(sigDer, seq);
  if (ints.length !== 2) throw new Error('der_sig_bad_int_count');
  const readInt = (node: Der): Uint8Array => {
    if (node.tag !== 0x02) throw new Error('der_sig_not_integer');
    let bytes = sigDer.slice(node.contentStart, node.end);
    while (bytes.length > 1 && bytes[0] === 0x00) bytes = bytes.slice(1);
    if (bytes.length > intLen) throw new Error('der_sig_int_too_long');
    const padded = new Uint8Array(intLen);
    padded.set(bytes, intLen - bytes.length);
    return padded;
  };
  const r = readInt(ints[0]);
  const s = readInt(ints[1]);
  const out = new Uint8Array(intLen * 2);
  out.set(r, 0);
  out.set(s, intLen);
  return out;
}

/**
 * Parse a DER X.509 certificate, extracting the TBS bytes, SPKI, outer
 * signature (raw r||s), and validity window. Assumes ECDSA P-256.
 *
 * Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
 * TBSCertificate ::= SEQUENCE {
 *   [0] version OPTIONAL, serialNumber, signature, issuer, validity,
 *   subject, subjectPublicKeyInfo, ... }
 */
export function parseCertificate(der: Uint8Array): ParsedCert {
  const certSeq = readDer(der, 0, der.length);
  if (certSeq.tag !== 0x30) throw new Error('cert_not_sequence');
  const top = readChildren(der, certSeq);
  if (top.length < 3) throw new Error('cert_bad_structure');
  const tbs = top[0];
  if (tbs.tag !== 0x30) throw new Error('tbs_not_sequence');
  const sigValue = top[2];
  if (sigValue.tag !== 0x03) throw new Error('sig_not_bitstring');

  const tbsBytes = slice(der, tbs);

  // outer signature: BIT STRING, first content byte is unused-bits count (0).
  const sigDer = der.slice(sigValue.contentStart + 1, sigValue.end);
  const signatureRaw = ecdsaDerToRaw(sigDer);

  // Walk TBS fields by position. version [0] (0xA0) is optional.
  const tbsFields = readChildren(der, tbs);
  let idx = 0;
  if (tbsFields[idx]?.tag === 0xa0) idx++; // skip explicit version
  idx++; // serialNumber
  idx++; // signature AlgorithmIdentifier
  idx++; // issuer Name
  const validity = tbsFields[idx++];
  if (!validity || validity.tag !== 0x30) throw new Error('validity_not_sequence');
  idx++; // subject Name
  const spki = tbsFields[idx++];
  if (!spki || spki.tag !== 0x30) throw new Error('spki_not_sequence');

  const validityFields = readChildren(der, validity);
  if (validityFields.length < 2) throw new Error('validity_bad');
  const notBefore = parseDerTime(der, validityFields[0]);
  const notAfter = parseDerTime(der, validityFields[1]);

  return {
    tbsBytes,
    spkiDer: slice(der, spki),
    signatureRaw,
    notBefore,
    notAfter,
    der,
  };
}

// ============================================================
// Crypto primitives (SubtleCrypto, ECDSA P-256 / SHA-256)
// ============================================================

async function importEcdsaP256SpkiKey(spkiDer: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'spki',
    spkiDer as unknown as ArrayBuffer,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
}

/** Verify an ES256 signature (raw r||s) over `data` with an SPKI key. */
async function verifyEs256(
  spkiDer: Uint8Array,
  signatureRaw: Uint8Array,
  data: Uint8Array,
): Promise<boolean> {
  let key: CryptoKey;
  try {
    key = await importEcdsaP256SpkiKey(spkiDer);
  } catch {
    return false;
  }
  return crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    signatureRaw as unknown as ArrayBuffer,
    data as unknown as ArrayBuffer,
  );
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const d = await crypto.subtle.digest('SHA-256', data as unknown as ArrayBuffer);
  return new Uint8Array(d);
}

// ============================================================
// Apple Root CA G3 pin
// ============================================================
//
// SHA-256 fingerprint of the Apple Root CA G3 certificate (DER), lowercase
// hex, no colons. This is the single trust anchor for the whole chain; pin
// verification compares SHA-256(root DER) from the JWS x5c against this value.
//
// Verified 2026-05-30 by downloading the official cert and hashing it:
//   curl -fsSL -o AppleRootCA-G3.cer \
//     https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
//   openssl x509 -in AppleRootCA-G3.cer -inform DER -noout -fingerprint -sha256
//   # subject=CN=Apple Root CA - G3, OU=Apple Certification Authority,
//   #         O=Apple Inc., C=US
//   # SHA256 = 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:
//   #          7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
// (openssl and `shasum -a 256` agree.) See https://www.apple.com/certificateauthority/
export const APPLE_ROOT_CA_G3_SHA256 =
  '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';

// ============================================================
// Errors
// ============================================================

export class AppleJwsVerifyError extends Error {
  constructor(
    readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
    this.name = 'AppleJwsVerifyError';
  }
}

// ============================================================
// Public API
// ============================================================

/**
 * Reconstruct the JWS signing input (`${headerB64}.${payloadB64}`) as ASCII
 * bytes. Exported so tests can assert the exact bytes that get ECDSA-verified.
 */
export function jwsSigningInput(jws: string): Uint8Array {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new Error('jws_malformed');
  return new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
}

/**
 * Full verification of an Apple App Store Server API JWS:
 *   1. split + decode header; require alg=ES256 and a 3-cert x5c
 *   2. parse each cert; pin SHA-256(root DER) to Apple Root CA G3
 *   3. check leaf + intermediate + root validity windows
 *   4. verify chain: leaf signed-by intermediate, intermediate signed-by root,
 *      root self-signature (sanity)
 *   5. ECDSA-verify the JWS signature over ASCII `${header}.${payload}` with
 *      the leaf's SPKI key
 *   6. return decoded payload
 *
 * @param opts.expectedRootSha256 overridable ONLY for tests (to exercise the
 *   pin-rejection path with a self-signed chain). Production callers MUST NOT
 *   pass this — it defaults to the real Apple Root CA G3 pin.
 * @param opts.now overridable for tests; defaults to Date.now().
 */
export async function verifyAppleJwsChain<P>(
  jws: string,
  opts?: { expectedRootSha256?: string; now?: number },
): Promise<P> {
  const expectedRoot = opts?.expectedRootSha256 ?? APPLE_ROOT_CA_G3_SHA256;
  const now = opts?.now ?? Date.now();

  const parts = jws.split('.');
  if (parts.length !== 3) throw new AppleJwsVerifyError('jws_malformed');
  const [headerB64, payloadB64, sigB64] = parts;

  let header: { alg?: string; x5c?: string[] };
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(headerB64)));
  } catch {
    throw new AppleJwsVerifyError('jws_header_decode_failed');
  }
  if (header.alg !== 'ES256') {
    throw new AppleJwsVerifyError('jws_unexpected_alg', `alg=${header.alg}`);
  }
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3) {
    throw new AppleJwsVerifyError('jws_x5c_unexpected_length', `len=${x5c?.length}`);
  }

  let leaf: ParsedCert;
  let intermediate: ParsedCert;
  let root: ParsedCert;
  try {
    leaf = parseCertificate(base64ToBytes(x5c[0]));
    intermediate = parseCertificate(base64ToBytes(x5c[1]));
    root = parseCertificate(base64ToBytes(x5c[2]));
  } catch (e) {
    throw new AppleJwsVerifyError(
      'cert_parse_failed',
      e instanceof Error ? e.message : String(e),
    );
  }

  // --- 2. pin the root ---
  const rootFp = bytesToHex(await sha256(root.der));
  if (!bytesEqual(hexToBytes(rootFp), hexToBytes(expectedRoot))) {
    throw new AppleJwsVerifyError('root_pin_mismatch', `got=${rootFp}`);
  }

  // --- 3. validity windows ---
  for (const [name, cert] of [
    ['leaf', leaf],
    ['intermediate', intermediate],
    ['root', root],
  ] as const) {
    if (now < cert.notBefore) throw new AppleJwsVerifyError('cert_not_yet_valid', name);
    if (now > cert.notAfter) throw new AppleJwsVerifyError('cert_expired', name);
  }

  // --- 4. chain signatures ---
  if (!(await verifyEs256(intermediate.spkiDer, leaf.signatureRaw, leaf.tbsBytes))) {
    throw new AppleJwsVerifyError('chain_leaf_sig_invalid');
  }
  if (
    !(await verifyEs256(root.spkiDer, intermediate.signatureRaw, intermediate.tbsBytes))
  ) {
    throw new AppleJwsVerifyError('chain_intermediate_sig_invalid');
  }
  if (!(await verifyEs256(root.spkiDer, root.signatureRaw, root.tbsBytes))) {
    throw new AppleJwsVerifyError('chain_root_self_sig_invalid');
  }

  // --- 5. verify the JWS signature with the leaf key ---
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const jwsSig = base64UrlToBytes(sigB64); // JOSE raw r||s, 64 bytes for ES256
  if (!(await verifyEs256(leaf.spkiDer, jwsSig, signingInput))) {
    throw new AppleJwsVerifyError('jws_signature_invalid');
  }

  // --- 6. decode payload ---
  let payload: P;
  try {
    payload = JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadB64))) as P;
  } catch {
    throw new AppleJwsVerifyError('jws_payload_decode_failed');
  }
  return payload;
}
