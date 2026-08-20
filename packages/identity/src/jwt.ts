import { jwtVerify, createRemoteJWKSet, type JWTVerifyGetKey } from 'jose';
import { SupabaseJwtPayload } from './schema';

// Supabase migrated user JWTs to asymmetric signing keys (ES256/RS256). The
// legacy HS256 + project JWT secret path now only verifies the platform
// anon/service_role API keys, not user-issued tokens. We verify against the
// project's JWKS endpoint instead — `jose` caches the keyset in-process
// after the first fetch (per Worker isolate), so steady-state cost is zero.
//
// JWKS URL convention: `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`.

// Algorithm allowlist — anything outside this set is rejected during
// verification, which closes the legacy HS256 path even if a JWKS
// entry ever advertised it.
export const ALLOWED_JWT_ALGS = ['ES256', 'RS256', 'EdDSA'] as const;

const JWKS_CACHE = new Map<string, JWTVerifyGetKey>();

function getJwks(supabaseUrl: string): JWTVerifyGetKey {
  let jwks = JWKS_CACHE.get(supabaseUrl);
  if (!jwks) {
    const url = new URL('/auth/v1/.well-known/jwks.json', supabaseUrl);
    jwks = createRemoteJWKSet(url);
    JWKS_CACHE.set(supabaseUrl, jwks);
  }
  return jwks;
}

interface VerifyJwtOptions {
  issuer?: string;
}

function authIssuer(supabaseUrl: string): string {
  return new URL('/auth/v1', supabaseUrl).toString();
}

/**
 * Inner verification: given a resolved JWKS, verify signature + algorithm
 * + payload shape. Exposed so tests can pass a local JWKS without hitting
 * jose's network fetcher (which in Node bypasses globalThis.fetch and
 * goes straight to node:https, making it untestable via fetch stubs).
 *
 * Production callers use `verifySupabaseJwt`, which wires the remote
 * JWKS up automatically.
 */
export async function verifyJwtWithJwks(
  token: string,
  jwks: JWTVerifyGetKey,
  opts: VerifyJwtOptions = {},
): Promise<SupabaseJwtPayload> {
  const { payload } = await jwtVerify(token, jwks, {
    // Allow whichever asymmetric algorithm the project's signing key uses.
    // Locking to ES256/RS256/EdDSA blocks the deprecated HS256 path.
    algorithms: [...ALLOWED_JWT_ALGS],
    audience: 'authenticated',
    issuer: opts.issuer,
  });
  return SupabaseJwtPayload.parse(payload);
}

export async function verifySupabaseJwt(
  token: string,
  supabaseUrl: string,
): Promise<SupabaseJwtPayload> {
  return verifyJwtWithJwks(token, getJwks(supabaseUrl), {
    issuer: authIssuer(supabaseUrl),
  });
}
