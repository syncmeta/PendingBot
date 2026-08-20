import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import { sha256Hex } from '../src/lib/device-grant-scopes';
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

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let deviceLoginRoutes: any;

beforeEach(async () => {
  ({ deviceLoginRoutes } = await import('../src/routes/device-login'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/device-login', deviceLoginRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

async function createChallenge(db: FakeDb) {
  const res = await appFor(db).request('/v1/device-login/challenges', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      appKind: 'pendingcrew_macos',
      deviceName: 'MacBook Pro',
      devicePublicKey: 'public-key-material-long-enough',
      scopes: ['subject:read', 'crew:read', 'runner:write'],
    }),
  });
  expect(res.status).toBe(200);
  return await res.json() as {
    challengeId: string;
    secret: string;
    qrPayload: string;
    status: string;
  };
}

async function createPendingBotMacChallenge(db: FakeDb, scopes = ['subject:read', 'crew:read', 'crew:write']) {
  const res = await appFor(db).request('/v1/device-login/challenges', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      appKind: 'pendingbot_macos',
      deviceName: 'PendingBot Mac',
      devicePublicKey: 'pendingbot-public-key-material-long-enough',
      scopes,
    }),
  });
  expect(res.status).toBe(200);
  return await res.json() as {
    challengeId: string;
    secret: string;
    qrPayload: string;
    status: string;
  };
}

describe('POST /v1/device-login/challenges', () => {
  it('creates an unauthenticated QR login challenge without storing the raw secret', async () => {
    const db = makeFakeDb();
    const body = await createChallenge(db);

    expect(body.status).toBe('pending');
    expect(body.secret).toMatch(/^pdc_/);
    expect(body.qrPayload).toContain(`/d/${body.challengeId}`);
    expect(body.qrPayload).toContain(encodeURIComponent(body.secret));
    expect(body.qrPayload).toContain('k=pendingcrew_macos');

    const row = db.rows.subject_device_login_challenges[0];
    expect(row.id).toBe(body.challengeId);
    expect(row.challenge_secret_hash).not.toBe(body.secret);
    expect(row.app_kind).toBe('pendingcrew_macos');
    expect(row.requested_scopes).toEqual(['subject:read', 'crew:read', 'runner:write']);
  });
});

describe('POST /v1/device-login/challenges/:id/approve', () => {
  it('lets a signed-in phone approve a challenge for an authorized subject', async () => {
    const db = makeFakeDb();
    const challenge = await createChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    db.rpcs = {
      subject_can_authorize_device_grant: (args) => {
        expect(args).toEqual({
          p_subject_id: subjectId,
          p_user_id: 'user-1',
          p_grant_kind: 'pendingcrew_runner',
        });
        return { data: true, error: null };
      },
    };

    const res = await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingcrew_runner',
        scopes: ['subject:read', 'runner:write'],
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ ok: true, status: 'approved' });
    expect(db.rows.subject_device_login_challenges[0]).toMatchObject({
      status: 'approved',
      approved_subject_id: subjectId,
      approved_by_user_id: 'user-1',
      grant_kind: 'pendingcrew_runner',
      requested_scopes: ['subject:read', 'runner:write'],
    });
  });

  it('lets PendingCrew control approve crew and runner scopes for the operator client', async () => {
    const db = makeFakeDb();
    const challenge = await createChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    db.rpcs = {
      subject_can_authorize_device_grant: (args) => {
        expect(args).toEqual({
          p_subject_id: subjectId,
          p_user_id: 'user-1',
          p_grant_kind: 'pendingcrew_control',
        });
        return { data: true, error: null };
      },
    };

    const res = await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingcrew_control',
        scopes: ['subject:read', 'crew:read', 'runner:write'],
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ ok: true, status: 'approved' });
    expect(db.rows.subject_device_login_challenges[0]).toMatchObject({
      status: 'approved',
      approved_subject_id: subjectId,
      approved_by_user_id: 'user-1',
      grant_kind: 'pendingcrew_control',
      requested_scopes: ['subject:read', 'crew:read', 'runner:write'],
    });
  });

  it('rejects an app/grant mismatch', async () => {
    const db = makeFakeDb();
    const challenge = await createPendingBotMacChallenge(db, ['subject:read']);

    const approve = await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId: '11111111-1111-4111-8111-111111111111',
        grantKind: 'pendingcrew_runner',
        scopes: ['subject:read'],
      }),
    });

    expect(approve.status).toBe(400);
    await expect(approve.json()).resolves.toMatchObject({
      error: { code: 'invalid_body' },
    });
  });

  it('lets PendingBot Mac approve a client grant with crew read/write scopes', async () => {
    const db = makeFakeDb();
    const challenge = await createPendingBotMacChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    db.rows.subjects = [{
      id: subjectId,
      kind: 'user_account',
      user_id: 'user-1',
      status: 'active',
    }];
    db.rpcs = {
      subject_can_authorize_device_grant: (args) => {
        expect(args).toEqual({
          p_subject_id: subjectId,
          p_user_id: 'user-1',
          p_grant_kind: 'pendingbot_client',
        });
        return { data: true, error: null };
      },
    };

    const approve = await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingbot_client',
        scopes: ['subject:read', 'crew:read', 'crew:write'],
      }),
    });

    expect(approve.status).toBe(200);
    await expect(approve.json()).resolves.toEqual({ ok: true, status: 'approved' });
    expect(db.rows.subject_device_login_challenges[0]).toMatchObject({
      status: 'approved',
      app_kind: 'pendingbot_macos',
      approved_subject_id: subjectId,
      approved_by_user_id: 'user-1',
      grant_kind: 'pendingbot_client',
      requested_scopes: ['subject:read', 'crew:read', 'crew:write'],
    });
  });

  it('rejects group subjects for PendingBot Mac session login', async () => {
    const db = makeFakeDb();
    const challenge = await createPendingBotMacChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    db.rows.subjects = [{
      id: subjectId,
      kind: 'group_account',
      user_id: null,
      status: 'active',
    }];
    db.rpcs = {
      subject_can_authorize_device_grant: () => ({ data: true, error: null }),
    };

    const approve = await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingbot_client',
        scopes: ['subject:read', 'crew:read', 'crew:write'],
      }),
    });

    expect(approve.status).toBe(403);
    await expect(approve.json()).resolves.toMatchObject({
      error: { code: 'forbidden' },
    });
    expect(db.rows.subject_device_login_challenges[0]).toMatchObject({
      status: 'pending',
      app_kind: 'pendingbot_macos',
    });
  });

  it('rejects runner scopes on a PendingBot Mac client grant', async () => {
    const db = makeFakeDb();
    const challenge = await createPendingBotMacChallenge(db, ['subject:read', 'runner:write']);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    db.rpcs = {
      subject_can_authorize_device_grant: () => ({ data: true, error: null }),
    };

    const approve = await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingbot_client',
        scopes: ['subject:read', 'runner:write'],
      }),
    });

    expect(approve.status).toBe(400);
    await expect(approve.json()).resolves.toMatchObject({
      error: { code: 'invalid_body' },
    });
    expect(db.rows.subject_device_login_challenges[0]).toMatchObject({
      status: 'pending',
      app_kind: 'pendingbot_macos',
      requested_scopes: ['subject:read', 'runner:write'],
    });
    expect(db.rows.subject_device_login_challenges[0]).not.toHaveProperty('grant_kind');
  });
});

describe('GET /v1/device-login/challenges/:id', () => {
  it('issues a single device grant token after approval and consumes the challenge', async () => {
    const db = makeFakeDb();
    const challenge = await createChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    db.rpcs = {
      subject_can_authorize_device_grant: () => ({ data: true, error: null }),
      consume_subject_device_login_challenge: (args) => {
        const row = db.rows.subject_device_login_challenges[0];
        row.status = 'consumed';
        row.issued_grant_id = args.p_grant_id;
        db.rows.subject_device_grants ??= [];
        db.rows.subject_device_grants.push({
          id: args.p_grant_id,
          subject_id: subjectId,
          granted_by_user_id: 'user-1',
          app_kind: 'pendingcrew_macos',
          grant_kind: 'pendingcrew_control',
          scopes: ['subject:read', 'crew:read'],
          token_hash: args.p_token_hash,
          status: 'active',
        });
        return {
          data: {
            grant_id: args.p_grant_id,
            subject_id: subjectId,
            grant_kind: 'pendingcrew_control',
            scopes: ['subject:read', 'crew:read'],
          },
          error: null,
        };
      },
    };

    await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingcrew_control',
        scopes: ['subject:read', 'crew:read'],
      }),
    });

    const poll = await appFor(db).request(
      `/v1/device-login/challenges/${challenge.challengeId}?secret=${encodeURIComponent(challenge.secret)}`,
    );
    expect(poll.status).toBe(200);
    const body = await poll.json() as { deviceGrantToken: string; grantId: string };
    expect(body.deviceGrantToken).toMatch(/^pdg_/);
    expect(body.grantId).toBeTruthy();

    expect(db.rows.subject_device_grants).toHaveLength(1);
    expect(db.rows.subject_device_grants[0]).toMatchObject({
      id: body.grantId,
      subject_id: subjectId,
      granted_by_user_id: 'user-1',
      app_kind: 'pendingcrew_macos',
      grant_kind: 'pendingcrew_control',
      scopes: ['subject:read', 'crew:read'],
      status: 'active',
    });
    expect(db.rows.subject_device_grants[0].token_hash).not.toBe(body.deviceGrantToken);
    expect(db.rows.subject_device_login_challenges[0]).toMatchObject({
      status: 'consumed',
      issued_grant_id: body.grantId,
    });
  });

  it('also issues a family SSO credential for the approver and returns it on poll', async () => {
    const db = makeFakeDb();
    const challenge = await createChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const grantedByUserId = '22222222-2222-4222-8222-222222222222';
    let familyArgs: Record<string, unknown> | null = null;
    db.rpcs = {
      subject_can_authorize_device_grant: () => ({ data: true, error: null }),
      consume_subject_device_login_challenge: (args) => {
        const row = db.rows.subject_device_login_challenges[0];
        row.status = 'consumed';
        row.issued_grant_id = args.p_grant_id;
        return {
          data: {
            grant_id: args.p_grant_id,
            subject_id: subjectId,
            grant_kind: 'pendingcrew_control',
            scopes: ['subject:read', 'crew:read'],
            granted_by_user_id: grantedByUserId,
            device_name: 'Mac',
          },
          error: null,
        };
      },
      issue_family_sso_credential: (args) => {
        familyArgs = args;
        db.rows.family_sso_credentials ??= [];
        db.rows.family_sso_credentials.push({
          id: args.p_id,
          user_id: args.p_user_id,
          token_hash: args.p_token_hash,
          device_name: args.p_device_name,
        });
        return { data: args.p_id, error: null };
      },
    };

    await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingcrew_control',
        scopes: ['subject:read', 'crew:read'],
      }),
    });

    const poll = await appFor(db).request(
      `/v1/device-login/challenges/${challenge.challengeId}?secret=${encodeURIComponent(challenge.secret)}`,
    );
    expect(poll.status).toBe(200);
    const body = await poll.json() as { familyCredential: string | null };
    expect(body.familyCredential).toMatch(/^pfa_/);

    // The credential was minted for the *approving* user, hashed (never raw).
    expect(familyArgs).not.toBeNull();
    const args = familyArgs as unknown as Record<string, unknown>;
    expect(args.p_user_id).toBe(grantedByUserId);
    expect(args.p_device_name).toBe('Mac');
    expect(typeof args.p_id).toBe('string');
    const expectedHash = await sha256Hex(body.familyCredential as string);
    expect(args.p_token_hash).toBe(expectedHash);
    expect(args.p_token_hash).not.toBe(body.familyCredential);

    expect(db.rows.family_sso_credentials).toHaveLength(1);
    expect(db.rows.family_sso_credentials[0].token_hash).not.toBe(body.familyCredential);
  });

  it('returns a Supabase token hash when consuming a PendingBot Mac login', async () => {
    const db = makeFakeDb();
    const challenge = await createPendingBotMacChallenge(db);
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const grantedByUserId = '22222222-2222-4222-8222-222222222222';
    db.rows.subjects = [{
      id: subjectId,
      kind: 'user_account',
      user_id: grantedByUserId,
      status: 'active',
    }];
    db.auth = {
      users: {
        [grantedByUserId]: { email: 'user@example.com' },
      },
    };
    db.rpcs = {
      subject_can_authorize_device_grant: () => ({ data: true, error: null }),
      consume_subject_device_login_challenge: (args) => {
        const row = db.rows.subject_device_login_challenges[0];
        row.status = 'consumed';
        row.issued_grant_id = args.p_grant_id;
        return {
          data: {
            grant_id: args.p_grant_id,
            subject_id: subjectId,
            grant_kind: 'pendingbot_client',
            scopes: ['subject:read', 'crew:read', 'crew:write'],
            granted_by_user_id: grantedByUserId,
            device_name: 'PendingBot Mac',
          },
          error: null,
        };
      },
    };

    await appFor(db).request(`/v1/device-login/challenges/${challenge.challengeId}/approve`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': grantedByUserId,
      },
      body: JSON.stringify({
        secret: challenge.secret,
        subjectId,
        grantKind: 'pendingbot_client',
        scopes: ['subject:read', 'crew:read', 'crew:write'],
      }),
    });

    const poll = await appFor(db).request(
      `/v1/device-login/challenges/${challenge.challengeId}?secret=${encodeURIComponent(challenge.secret)}`,
    );
    expect(poll.status).toBe(200);
    const body = await poll.json() as { supabaseTokenHash: string | null; deviceGrantToken: string };
    expect(body.deviceGrantToken).toMatch(/^pdg_/);
    expect(body.supabaseTokenHash).toBe('hash-for-user@example.com');
    expect(db.auth.generatedLinks).toEqual([{ type: 'magiclink', email: 'user@example.com' }]);
  });
});
