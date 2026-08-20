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
    let email: string | null = null;
    try {
      const { payload } = await jwtVerify(assertion, teamJwks(teamDomain), {
        issuer: `https://${teamDomain}`,
        audience: aud,
      });
      // Access mints the JWT from the authenticated identity; `email` is the
      // human IdP/OTP login (service-token grants carry `common_name` instead,
      // which board doesn't allow — so a missing email is a hard reject).
      email = typeof payload.email === 'string' ? payload.email.toLowerCase() : null;
    } catch {
      return jsonError(c, 403, 'forbidden', { message: 'Access 凭证无效' });
    }
    if (!email) {
      return jsonError(c, 403, 'forbidden', { message: 'Access 凭证缺少身份' });
    }
    c.set('boardEmail', email);
    await next();
  };
}

// Authorization gate for the board console — the verified Access email must be
// in the server-side admin allowlist (BOARD_ADMIN_EMAILS, comma-separated).
//
// This is a SECOND, independent authority from the Access policy: even if the
// Access app's allow-policy is ever widened by mistake, the origin still only
// admits emails on this list. FAIL-CLOSED — an empty/unset allowlist denies
// everyone. Mount AFTER requireCfAccess (which populates c.var.boardEmail).
export function requireBoardAdmin(): MiddlewareHandler<AppBindings> {
  return async (c, next) => {
    // Lowercase locally too — don't depend on requireCfAccess having normalized.
    const email = c.var.boardEmail?.toLowerCase();
    const allow = (c.env.BOARD_ADMIN_EMAILS ?? '')
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean);
    if (!email || allow.length === 0 || !allow.includes(email)) {
      return jsonError(c, 403, 'forbidden', { message: '非授权管理员' });
    }
    await next();
  };
}
