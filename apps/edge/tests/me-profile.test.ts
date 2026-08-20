import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type Row,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<{
    Bindings: { SUPABASE_URL: string; SUPABASE_JWT_SECRET: string };
    Variables: { userId?: string; userJwt?: string };
  }> => async (c, next) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', u);
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

// GET /profile piggybacks the idempotent signup bonus on the read. Not what
// these tests are about, and it would go hunting for a Polar customer.
vi.mock('../src/lib/billing-grant', () => ({
  grantSignupBonus: vi.fn(async () => undefined),
  creditRedemptionToPolar: vi.fn(async () => 0),
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let meRoutes: any;

beforeEach(async () => {
  ({ meRoutes } = await import('../src/routes/me'));
});

function userRow(customFields: Row | null): Row {
  return { id: 'user-1', custom_fields: customFields };
}

async function request(
  db: FakeDb,
  init: RequestInit & { method?: string } = {},
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/me', meRoutes);
  const res = await app.request(
    '/v1/me/profile',
    {
      ...init,
      headers: { 'x-test-user-id': 'user-1', 'content-type': 'application/json', ...(init.headers ?? {}) },
    },
    makeFakeEnv(db),
  );
  return { status: res.status, body: (await res.json()) as Record<string, unknown> };
}

const patch = (db: FakeDb, body: unknown) =>
  request(db, { method: 'PATCH', body: JSON.stringify(body) });

/** custom_fields as it stands after the route's UPDATE. */
function storedFields(db: FakeDb): Row {
  const last = db.updates.at(-1);
  return (last?.patch.custom_fields ?? {}) as Row;
}

describe('GET /v1/me/profile', () => {
  it('defaults both preferences when custom_fields is empty', async () => {
    const db = makeFakeDb({ users: [userRow(null)] });
    const r = await request(db);
    expect(r.status).toBe(200);
    expect(r.body).toEqual({
      notification_preview_mode: 'generic',
      model_reveal_preference: 'follow_bot',
    });
  });

  it('returns the stored model_reveal_preference', async () => {
    const db = makeFakeDb({ users: [userRow({ model_reveal_preference: 'always_blind' })] });
    const r = await request(db);
    expect(r.body.model_reveal_preference).toBe('always_blind');
  });

  it('normalises an unknown model_reveal_preference back to follow_bot', async () => {
    // A hand-edited JSON blob or a future build's value must not reach the
    // client as-is — follow_bot is the pre-feature behaviour.
    const db = makeFakeDb({ users: [userRow({ model_reveal_preference: 'nonsense' })] });
    const r = await request(db);
    expect(r.body.model_reveal_preference).toBe('follow_bot');
  });
});

describe('PATCH /v1/me/profile', () => {
  it('writes model_reveal_preference when it is the ONLY field sent', async () => {
    // Regression: the route used to bail out on
    // `notification_preview_mode === undefined`, silently swallowing a
    // patch that carried only the newer knob.
    const db = makeFakeDb({ users: [userRow({ notification_preview_mode: 'name' })] });
    const r = await patch(db, { model_reveal_preference: 'always_real' });
    expect(r.status).toBe(200);
    expect(db.updates).toHaveLength(1);
    expect(storedFields(db).model_reveal_preference).toBe('always_real');
    expect(r.body).toEqual({ ok: true, model_reveal_preference: 'always_real' });
  });

  it('leaves the other preference alone when only one is sent', async () => {
    const db = makeFakeDb({ users: [userRow({ notification_preview_mode: 'name_content' })] });
    await patch(db, { model_reveal_preference: 'always_blind' });
    expect(storedFields(db).notification_preview_mode).toBe('name_content');
  });

  it('still writes notification_preview_mode alone', async () => {
    const db = makeFakeDb({ users: [userRow({ model_reveal_preference: 'always_blind' })] });
    const r = await patch(db, { notification_preview_mode: 'name' });
    expect(storedFields(db)).toEqual({
      model_reveal_preference: 'always_blind',
      notification_preview_mode: 'name',
    });
    expect(r.body).toEqual({ ok: true, notification_preview_mode: 'name' });
  });

  it('writes both when both are sent', async () => {
    const db = makeFakeDb({ users: [userRow(null)] });
    const r = await patch(db, {
      notification_preview_mode: 'generic',
      model_reveal_preference: 'always_real',
    });
    expect(storedFields(db)).toEqual({
      notification_preview_mode: 'generic',
      model_reveal_preference: 'always_real',
    });
    expect(r.body).toEqual({
      ok: true,
      notification_preview_mode: 'generic',
      model_reveal_preference: 'always_real',
    });
  });

  it('preserves unrelated custom_fields keys', async () => {
    const db = makeFakeDb({ users: [userRow({ avatar_seed: 'seed-9', bootstrapped: '1' })] });
    await patch(db, { model_reveal_preference: 'always_blind' });
    expect(storedFields(db)).toEqual({
      avatar_seed: 'seed-9',
      bootstrapped: '1',
      model_reveal_preference: 'always_blind',
    });
  });

  it('writes nothing for an empty body', async () => {
    const db = makeFakeDb({ users: [userRow(null)] });
    const r = await patch(db, {});
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ok: true });
    expect(db.updates).toHaveLength(0);
  });

  it('rejects an unknown model_reveal_preference with 400', async () => {
    const db = makeFakeDb({ users: [userRow(null)] });
    const r = await patch(db, { model_reveal_preference: 'always_maybe' });
    expect(r.status).toBe(400);
    expect(db.updates).toHaveLength(0);
  });
});
