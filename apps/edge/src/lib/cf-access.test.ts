import { describe, expect, it } from 'vitest';
import { Hono } from 'hono';
import { requireCfAccess, requireBoardAdmin } from './cf-access';
import type { AppBindings } from '../types';

function appWithGate() {
  const app = new Hono<AppBindings>();
  app.use('*', requireCfAccess());
  app.get('/x', (c) => c.json({ ok: true }));
  return app;
}

const ENV_CONFIGURED = {
  CF_ACCESS_TEAM_DOMAIN: 'team.cloudflareaccess.com',
  CF_ACCESS_AUD: 'aud-tag',
} as Parameters<Hono<AppBindings>['request']>[2];

describe('requireCfAccess', () => {
  it('fail-closed: rejects when env vars are unset', async () => {
    const res = await appWithGate().request('/x', {}, {} as never);
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('forbidden');
  });

  it('rejects when the Access assertion header is missing', async () => {
    const res = await appWithGate().request('/x', {}, ENV_CONFIGURED);
    expect(res.status).toBe(403);
  });

  it('rejects a malformed assertion without reaching JWKS', async () => {
    const res = await appWithGate().request(
      '/x',
      { headers: { 'Cf-Access-Jwt-Assertion': 'not-a-jwt' } },
      ENV_CONFIGURED,
    );
    expect(res.status).toBe(403);
  });
});

// Authorization gate. requireCfAccess (verified above) populates boardEmail;
// here we drive boardEmail directly via a stub middleware to isolate the
// allowlist logic from JWT verification.
function appWithAdminGate(email?: string) {
  const app = new Hono<AppBindings>();
  app.use('*', async (c, next) => {
    if (email) c.set('boardEmail', email);
    await next();
  });
  app.use('*', requireBoardAdmin());
  app.get('/x', (c) => c.json({ ok: true }));
  return app;
}

const withAllowlist = (list?: string) =>
  ({ BOARD_ADMIN_EMAILS: list }) as Parameters<Hono<AppBindings>['request']>[2];

describe('requireBoardAdmin', () => {
  it('admits an email on the allowlist', async () => {
    const res = await appWithAdminGate('me@x.com').request(
      '/x',
      {},
      withAllowlist('me@x.com'),
    );
    expect(res.status).toBe(200);
  });

  it('is case-insensitive on the email', async () => {
    const res = await appWithAdminGate('Me@X.com').request(
      '/x',
      {},
      withAllowlist('me@x.com'),
    );
    expect(res.status).toBe(200);
  });

  it('admits one of several comma-separated emails', async () => {
    const res = await appWithAdminGate('b@x.com').request(
      '/x',
      {},
      withAllowlist('a@x.com, b@x.com'),
    );
    expect(res.status).toBe(200);
  });

  it('rejects an email not on the allowlist', async () => {
    const res = await appWithAdminGate('nope@x.com').request(
      '/x',
      {},
      withAllowlist('me@x.com'),
    );
    expect(res.status).toBe(403);
  });

  it('fail-closed: rejects when the allowlist is empty', async () => {
    const res = await appWithAdminGate('me@x.com').request('/x', {}, withAllowlist(''));
    expect(res.status).toBe(403);
  });

  it('fail-closed: rejects when the allowlist is unset', async () => {
    const res = await appWithAdminGate('me@x.com').request('/x', {}, withAllowlist(undefined));
    expect(res.status).toBe(403);
  });

  it('rejects when no boardEmail was set (Access gate skipped)', async () => {
    const res = await appWithAdminGate(undefined).request('/x', {}, withAllowlist('me@x.com'));
    expect(res.status).toBe(403);
  });
});
