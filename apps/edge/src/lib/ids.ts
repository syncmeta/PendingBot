// Identifier validation helpers shared across routes.

// Match a canonical 36-char UUID (8-4-4-4-12, case-insensitive). Permissive
// on dashes / version digit on purpose — we accept any UUID that Postgres
// will accept, including uuidv4/uuidv7 and the rare nil variant.
export const UUID_RE = /^[0-9a-f-]{36}$/i;

export const isUuid = (s: unknown): s is string =>
  typeof s === 'string' && UUID_RE.test(s);

// Generate a UUIDv7 (RFC 9562): 48-bit big-endian Unix-ms timestamp,
// then version/variant bits, then random. Time-ordered so it preserves
// insert locality on a uuid primary key — matching what the DB's
// `pendingbot.uuidv7()` default produces.
//
// Used when the worker must know a row's id *before* the INSERT — e.g.
// audit_log rows are inserted by the async queue consumer, but
// enqueueAudit needs to return the id to its caller synchronously, and
// the same id doubles as the consumer's idempotency key.
export function uuidv7(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);

  const ms = Date.now();
  // 48-bit timestamp across bytes 0..5 (big-endian).
  bytes[0] = (ms / 0x10000000000) & 0xff;
  bytes[1] = (ms / 0x100000000) & 0xff;
  bytes[2] = (ms / 0x1000000) & 0xff;
  bytes[3] = (ms / 0x10000) & 0xff;
  bytes[4] = (ms / 0x100) & 0xff;
  bytes[5] = ms & 0xff;
  // Version 7 in the high nibble of byte 6; variant 10xx in byte 8.
  bytes[6] = (bytes[6]! & 0x0f) | 0x70;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;

  const hex: string[] = [];
  for (let i = 0; i < 16; i++) hex.push(bytes[i]!.toString(16).padStart(2, '0'));
  return (
    hex.slice(0, 4).join('') +
    '-' +
    hex.slice(4, 6).join('') +
    '-' +
    hex.slice(6, 8).join('') +
    '-' +
    hex.slice(8, 10).join('') +
    '-' +
    hex.slice(10, 16).join('')
  );
}
