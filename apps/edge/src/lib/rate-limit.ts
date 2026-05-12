import type { Context } from 'hono';
import type { AppBindings } from '../types';

// Thin wrapper around Cloudflare's RateLimit binding so route handlers
// don't repeat the same { error, retry-after } shape and key-resolution
// logic. Returns null on success or a Response when the caller is over
// the limit — callers do `const blocked = await rateLimitOrBlock(...);
// if (blocked) return blocked;`.

export interface RateLimitOptions {
  /// Override key. Defaults to userId, then CF-Connecting-IP, then 'anon'.
  key?: string;
}

/**
 * Apply a rate-limit binding to the current request. If the caller is
 * over the limit, returns a 429 Response ready to be returned from the
 * handler. If not, returns null and the handler continues.
 */
export async function rateLimitOrBlock(
  c: Context<AppBindings>,
  limiter: RateLimit,
  opts: RateLimitOptions = {},
): Promise<Response | null> {
  const key =
    opts.key ??
    c.var.userId ??
    c.req.header('CF-Connecting-IP') ??
    'anon';

  const { success } = await limiter.limit({ key });
  if (success) return null;

  return c.json(
    {
      error: 'rate_limited',
      message: '请求过于频繁,请稍后再试',
    },
    429,
  );
}
