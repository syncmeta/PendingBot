import { describe, expect, it } from 'vitest';
import { Hono } from 'hono';
import { rateLimitOrBlock } from './rate-limit';
import type { AppBindings } from '../types';

// Cloudflare's RateLimit binding at the type level is:
//   interface RateLimit { limit(opts: { key: string }): Promise<{ success: boolean }> }
// Tests fake one in-process so we can assert key resolution, success
// passthrough, and the 429 envelope shape without spinning Workers.

interface FakeBinding {
  limit: (opts: { key: string }) => Promise<{ success: boolean }>;
  callsWithKey: string[];
}

function fakeLimiter(success: boolean): FakeBinding {
  const callsWithKey: string[] = [];
  return {
    callsWithKey,
    limit: async ({ key }) => {
      callsWithKey.push(key);
      return { success };
    },
  };
}

describe('rateLimitOrBlock', () => {
  it('returns null on success — caller continues', async () => {
    const app = new Hono<AppBindings>();
    const limiter = fakeLimiter(true);
    let body: unknown;
    app.get('/x', async (c) => {
      const blocked = await rateLimitOrBlock(c, limiter as unknown as RateLimit);
      if (blocked) return blocked;
      return c.json({ ok: true });
    });
    const res = await app.request('/x', { headers: { 'CF-Connecting-IP': '1.2.3.4' } });
    body = await res.json();
    expect(res.status).toBe(200);
    expect(body).toEqual({ ok: true });
    expect(limiter.callsWithKey).toEqual(['1.2.3.4']);
  });

  it('returns a 429 envelope on failure', async () => {
    const app = new Hono<AppBindings>();
    const limiter = fakeLimiter(false);
    app.get('/x', async (c) => {
      const blocked = await rateLimitOrBlock(c, limiter as unknown as RateLimit);
      if (blocked) return blocked;
      return c.json({ ok: true });
    });
    const res = await app.request('/x', { headers: { 'CF-Connecting-IP': '1.2.3.4' } });
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({
      error: 'rate_limited',
      message: '请求过于频繁,请稍后再试',
    });
  });

  it('prefers userId from c.var when set', async () => {
    // requireSession middleware populates c.var.userId before
    // routes that require auth; rate-limit should bucket per user
    // when available so a single chatty user can't blow through the
    // shared IP bucket and starve everyone behind the same NAT.
    const app = new Hono<AppBindings>();
    const limiter = fakeLimiter(true);
    app.use('*', async (c, next) => {
      c.set('userId', 'user-7');
      await next();
    });
    app.get('/x', async (c) => {
      const blocked = await rateLimitOrBlock(c, limiter as unknown as RateLimit);
      if (blocked) return blocked;
      return c.json({ ok: true });
    });
    await app.request('/x', { headers: { 'CF-Connecting-IP': '1.2.3.4' } });
    expect(limiter.callsWithKey).toEqual(['user-7']);
  });

  it("falls back to CF-Connecting-IP when there's no userId", async () => {
    const app = new Hono<AppBindings>();
    const limiter = fakeLimiter(true);
    app.get('/x', async (c) => {
      const blocked = await rateLimitOrBlock(c, limiter as unknown as RateLimit);
      if (blocked) return blocked;
      return c.json({ ok: true });
    });
    await app.request('/x', { headers: { 'CF-Connecting-IP': '203.0.113.5' } });
    expect(limiter.callsWithKey).toEqual(['203.0.113.5']);
  });

  it("falls back to 'anon' when neither userId nor CF-Connecting-IP is present", async () => {
    const app = new Hono<AppBindings>();
    const limiter = fakeLimiter(true);
    app.get('/x', async (c) => {
      const blocked = await rateLimitOrBlock(c, limiter as unknown as RateLimit);
      if (blocked) return blocked;
      return c.json({ ok: true });
    });
    await app.request('/x');
    expect(limiter.callsWithKey).toEqual(['anon']);
  });

  it('honors an explicit override key', async () => {
    const app = new Hono<AppBindings>();
    const limiter = fakeLimiter(true);
    app.use('*', async (c, next) => {
      c.set('userId', 'user-7');
      await next();
    });
    app.get('/x', async (c) => {
      const blocked = await rateLimitOrBlock(c, limiter as unknown as RateLimit, {
        key: 'handle:abc-123',
      });
      if (blocked) return blocked;
      return c.json({ ok: true });
    });
    await app.request('/x');
    expect(limiter.callsWithKey).toEqual(['handle:abc-123']);
  });
});
