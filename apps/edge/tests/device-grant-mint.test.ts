import { beforeEach, describe, expect, it } from 'vitest';
import { Hono } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let deviceGrantRoutes: any;

beforeEach(async () => {
  ({ deviceGrantRoutes } = await import('../src/routes/device-grant'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/device-grant', deviceGrantRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

const SUBJECT_ID = '11111111-1111-4111-8111-111111111111';
const FAMILY_TOKEN = 'pfa_family-credential-token-material-long-enough';
const DEVICE_KEY = 'device-public-key-material-long-enough';

function mintBody(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    subjectId: SUBJECT_ID,
    grantKind: 'pendingcrew_control',
    scopes: ['subject:read', 'crew:read'],
    appKind: 'pendingcrew_macos',
    deviceName: 'PendingCrew Mac',
    devicePublicKey: DEVICE_KEY,
    ...overrides,
  });
}

describe('POST /v1/device-grant/mint', () => {
  it('mints a scoped device grant from a valid family credential', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      mint_device_grant_from_family: (args) => {
        // family token is passed hashed, never raw
        expect(args.p_family_token_hash).not.toBe(FAMILY_TOKEN);
        expect(typeof args.p_family_token_hash).toBe('string');
        expect(args.p_subject_id).toBe(SUBJECT_ID);
        expect(args.p_grant_kind).toBe('pendingcrew_control');
        expect(args.p_app_kind).toBe('pendingcrew_macos');
        expect(args.p_scopes).toEqual(['subject:read', 'crew:read']);
        expect(args.p_device_name).toBe('PendingCrew Mac');
        expect(args.p_device_public_key).toBe(DEVICE_KEY);
        expect(typeof args.p_grant_id).toBe('string');
        expect(typeof args.p_token_hash).toBe('string');
        db.rows.subject_device_grants ??= [];
        db.rows.subject_device_grants.push({
          id: args.p_grant_id,
          subject_id: SUBJECT_ID,
          grant_kind: 'pendingcrew_control',
          scopes: ['subject:read', 'crew:read'],
          token_hash: args.p_token_hash,
          status: 'active',
        });
        return {
          data: {
            grant_id: args.p_grant_id,
            subject_id: SUBJECT_ID,
            grant_kind: 'pendingcrew_control',
            scopes: ['subject:read', 'crew:read'],
          },
          error: null,
        };
      },
    };

    const res = await appFor(db).request('/v1/device-grant/mint', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${FAMILY_TOKEN}`,
      },
      body: mintBody(),
    });

    expect(res.status).toBe(200);
    const body = await res.json() as {
      deviceGrantToken: string;
      grantId: string;
      subjectId: string;
      grantKind: string;
      scopes: string[];
    };
    expect(body.deviceGrantToken).toMatch(/^pdg_/);
    expect(body.grantId).toBeTruthy();
    expect(body.subjectId).toBe(SUBJECT_ID);
    expect(body.grantKind).toBe('pendingcrew_control');
    expect(body.scopes).toEqual(['subject:read', 'crew:read']);

    // the raw token is never what we stored
    expect(db.rows.subject_device_grants).toHaveLength(1);
    expect(db.rows.subject_device_grants[0].token_hash).not.toBe(body.deviceGrantToken);
  });

  it('rejects scopes that exceed the grant kind', async () => {
    const db = makeFakeDb();
    let rpcCalled = false;
    db.rpcs = {
      mint_device_grant_from_family: () => {
        rpcCalled = true;
        return { data: null, error: null };
      },
    };

    const res = await appFor(db).request('/v1/device-grant/mint', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${FAMILY_TOKEN}`,
      },
      // pendingcrew_runner allows {subject:read, runner:read, runner:write} — crew:write is out of range
      body: mintBody({ grantKind: 'pendingcrew_runner', scopes: ['subject:read', 'crew:write'] }),
    });

    expect(res.status).toBe(400);
    await expect(res.json()).resolves.toMatchObject({ error: { code: 'invalid_body' } });
    expect(rpcCalled).toBe(false);
  });

  it('rejects a missing or non-pfa_ bearer token', async () => {
    const db = makeFakeDb();

    const missing = await appFor(db).request('/v1/device-grant/mint', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: mintBody(),
    });
    expect(missing.status).toBe(401);

    const wrongPrefix = await appFor(db).request('/v1/device-grant/mint', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer pdg_not-a-family-token-but-long-enough',
      },
      body: mintBody(),
    });
    expect(wrongPrefix.status).toBe(401);
  });

  it('maps a not-authorized rpc error to 403', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      mint_device_grant_from_family: () => ({
        data: null,
        error: { code: '42501', message: 'subject not authorized for grant kind' },
      }),
    };

    const res = await appFor(db).request('/v1/device-grant/mint', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${FAMILY_TOKEN}`,
      },
      body: mintBody(),
    });

    expect(res.status).toBe(403);
    await expect(res.json()).resolves.toMatchObject({ error: { code: 'forbidden' } });
  });
});
