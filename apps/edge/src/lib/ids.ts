// Identifier validation helpers shared across routes.

// Match a canonical 36-char UUID (8-4-4-4-12, case-insensitive). Permissive
// on dashes / version digit on purpose — we accept any UUID that Postgres
// will accept, including uuidv4/uuidv7 and the rare nil variant.
export const UUID_RE = /^[0-9a-f-]{36}$/i;

export const isUuid = (s: unknown): s is string =>
  typeof s === 'string' && UUID_RE.test(s);
