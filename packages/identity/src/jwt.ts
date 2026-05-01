import { jwtVerify, createRemoteJWKSet, type JWTVerifyGetKey } from 'jose';
import { SupabaseJwtPayload } from './schema';

// Supabase migrated user JWTs to asymmetric signing keys (ES256/RS256). The
// legacy HS256 + project JWT secret path now only verifies the platform
// anon/service_role API keys, not user-issued tokens. We verify against the
// project's JWKS endpoint instead — `jose` caches the keyset in-process
// after the first fetch (per Worker isolate), so steady-state cost is zero.
//
// JWKS URL convention: `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`.

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

export async function verifySupabaseJwt(
  token: string,
  supabaseUrl: string,
): Promise<SupabaseJwtPayload> {
  const { payload } = await jwtVerify(token, getJwks(supabaseUrl), {
    // Allow whichever asymmetric algorithm the project's signing key uses.
    // Locking to ES256/RS256/EdDSA blocks the deprecated HS256 path.
    algorithms: ['ES256', 'RS256', 'EdDSA'],
  });
  return SupabaseJwtPayload.parse(payload);
}
