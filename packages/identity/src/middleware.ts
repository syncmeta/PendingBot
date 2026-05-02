import type { Context, MiddlewareHandler } from 'hono';
import { verifySupabaseJwt } from './jwt';

// Hono middleware for products that mount this package. Both factories are
// generic over the product's Bindings/Variables shape — caller provides
// the fields they actually use.

export interface RequireSessionEnv {
  SUPABASE_URL: string;
}

export interface RequireSessionVars {
  userId?: string;
  userJwt?: string;
}

// `requireSession`: pulls Bearer JWT from Authorization header, verifies
// signature against the project's JWKS, sets c.var.userId / c.var.userJwt.
// Reject with 401 if missing/invalid.
export function requireSession(): MiddlewareHandler<{
  Bindings: RequireSessionEnv;
  Variables: RequireSessionVars;
}> {
  return async (c, next) => {
    const auth = c.req.header('authorization');
    if (!auth || !auth.toLowerCase().startsWith('bearer ')) {
      return c.json({ error: 'unauthorized', reason: 'missing bearer token' }, 401);
    }
    const token = auth.slice(7).trim();
    try {
      const payload = await verifySupabaseJwt(token, c.env.SUPABASE_URL);
      c.set('userId', payload.sub);
      c.set('userJwt', token);
    } catch (err) {
      return c.json(
        { error: 'unauthorized', reason: 'invalid token', detail: String(err) },
        401,
      );
    }
    await next();
  };
}

// `requireAdmin`: must come AFTER requireSession in middleware chain.
// Caller provides isAdmin lookup (e.g. SELECT is_admin FROM <product>.users WHERE id = ?).
export function requireAdmin<
  E extends RequireSessionEnv,
  V extends RequireSessionVars & { isAdmin?: boolean },
>(
  isAdminLookup: (c: Context<{ Bindings: E; Variables: V }>) => Promise<boolean>,
): MiddlewareHandler<{ Bindings: E; Variables: V }> {
  return async (c, next) => {
    if (!c.var.userId) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    const ok = await isAdminLookup(c);
    if (!ok) {
      return c.json({ error: 'forbidden' }, 403);
    }
    c.set('isAdmin', true as V['isAdmin']);
    await next();
  };
}
