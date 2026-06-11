// Cloudflare Access gate for the board console (/v1/board/*).
//
// Defense-in-depth layer UNDER the edge-level Access app: Cloudflare Access
// authenticates the browser at the edge and forwards a signed JWT in the
// `Cf-Access-Jwt-Assertion` header. We verify that JWT against the team's
// JWKS and the application AUD, so the board surface stays closed even if
// the Access app config is ever deleted or its path scope drifts — a request
// that didn't pass through Access has no valid assertion and is rejected.
//
// FAIL-CLOSED: missing CF_ACCESS_TEAM_DOMAIN / CF_ACCESS_AUD env rejects
// every request — there is deliberately no bypass var. Local `wrangler dev`
// board testing goes through an Access service token against the team JWKS,
// or exercises non-board routes.
//
// https://developers.cloudflare.com/cloudflare-one/identity/authorization-cookie/validating-json/
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { MiddlewareHandler } from 'hono';
import { jsonError } from './http-error';
import type { AppBindings } from '../types';

// jose caches the keyset in-process with refresh/backoff; one instance per
// team domain per isolate.
const JWKS_CACHE = new Map<string, JWTVerifyGetKey>();

function teamJwks(teamDomain: string): JWTVerifyGetKey {
  let jwks = JWKS_CACHE.get(teamDomain);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`https://${teamDomain}/cdn-cgi/access/certs`));
    JWKS_CACHE.set(teamDomain, jwks);
  }
  return jwks;
}

export function requireCfAccess(): MiddlewareHandler<AppBindings> {
  return async (c, next) => {
    const teamDomain = c.env.CF_ACCESS_TEAM_DOMAIN;
    const aud = c.env.CF_ACCESS_AUD;
    if (!teamDomain || !aud) {
      // Misconfiguration is indistinguishable from "gate removed" — close.
      return jsonError(c, 403, 'forbidden', { message: 'Access 网关未配置' });
    }
    const assertion = c.req.header('Cf-Access-Jwt-Assertion');
    if (!assertion) {
      return jsonError(c, 403, 'forbidden', { message: '缺少 Access 凭证' });
    }
    try {
      await jwtVerify(assertion, teamJwks(teamDomain), {
        issuer: `https://${teamDomain}`,
        audience: aud,
      });
    } catch {
      return jsonError(c, 403, 'forbidden', { message: 'Access 凭证无效' });
    }
    await next();
  };
}
