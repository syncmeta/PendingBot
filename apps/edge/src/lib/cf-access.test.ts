import { describe, expect, it } from 'vitest';
import { Hono } from 'hono';
import { requireCfAccess } from './cf-access';
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
