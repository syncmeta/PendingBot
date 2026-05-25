import { describe, expect, it } from 'vitest';
import {
  SignJWT,
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  generateSecret,
  type JWK,
  type KeyLike,
} from 'jose';
import { verifyJwtWithJwks } from '@pendingbot/identity';

// Tests target verifyJwtWithJwks (the inner kernel that takes a resolved
// JWKS) so we don't hit jose's network fetcher. In Node, jose's
// createRemoteJWKSet uses node:https directly — it doesn't go through
// globalThis.fetch, so test stubs can't intercept. The kernel covers
// every security-relevant path: algorithm allowlist, signature
// verification, expiry, payload schema. The outer verifySupabaseJwt
// just wires up the JWKS URL, one line that doesn't need a test.

interface SigningContext {
  privateKey: KeyLike;
  jwks: ReturnType<typeof createLocalJWKSet>;
}

async function setupJwks(): Promise<SigningContext> {
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const publicJwk = (await exportJWK(publicKey)) as JWK;
  publicJwk.kid = 'test-kid';
  publicJwk.alg = 'ES256';
  publicJwk.use = 'sig';
  const jwks = createLocalJWKSet({ keys: [publicJwk] });
  return { privateKey, jwks };
}

async function signEs256(
  privateKey: KeyLike,
  payload: Record<string, unknown>,
  opts?: { kid?: string; alg?: string },
): Promise<string> {
  return new SignJWT(payload)
    .setProtectedHeader({ alg: opts?.alg ?? 'ES256', kid: opts?.kid ?? 'test-kid' })
    .sign(privateKey);
}

describe('verifyJwtWithJwks', () => {
  it('accepts a well-formed ES256 token signed by the project JWKS', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000001',
      aud: 'authenticated',
      iss: 'https://example.supabase.co/auth/v1',
      role: 'authenticated',
      email: 'a@b.example',
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    const payload = await verifyJwtWithJwks(token, jwks, {
      issuer: 'https://example.supabase.co/auth/v1',
    });
    expect(payload.sub).toBe('00000000-0000-0000-0000-000000000001');
    expect(payload.email).toBe('a@b.example');
    expect(payload.role).toBe('authenticated');
  });

  it('rejects tokens whose issuer is not the project auth issuer', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000010',
      aud: 'authenticated',
      iss: 'https://other-project.supabase.co/auth/v1',
      role: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    await expect(
      verifyJwtWithJwks(token, jwks, {
        issuer: 'https://example.supabase.co/auth/v1',
      }),
    ).rejects.toThrow();
  });

  it('rejects HS256 tokens (algorithm allowlist blocks the legacy path)', async () => {
    // Supabase migrated user JWTs from HS256 to asymmetric. The allowlist
    // in jwt.ts deliberately excludes HS256 so a leaked / historical
    // HS256 secret can no longer be used to mint user tokens. Confirm
    // the path stays closed — this is the load-bearing assertion for
    // the post-migration security posture.
    const { jwks } = await setupJwks();
    const secret = await generateSecret('HS256');
    const hsToken = await new SignJWT({
      sub: '00000000-0000-0000-0000-000000000002',
      aud: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    })
      .setProtectedHeader({ alg: 'HS256' })
      .sign(secret);

    await expect(verifyJwtWithJwks(hsToken, jwks)).rejects.toThrow();
  });

  it('rejects expired tokens', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000003',
      aud: 'authenticated',
      iat: Math.floor(Date.now() / 1000) - 7200,
      exp: Math.floor(Date.now() / 1000) - 3600, // 1h in the past
    });

    await expect(verifyJwtWithJwks(token, jwks)).rejects.toThrow(/exp/i);
  });

  it('rejects tokens signed by a key not in the JWKS', async () => {
    // Two key pairs: the JWKS publishes A's public key, but the token
    // is signed by B. Signature verification must fail.
    const ctxA = await setupJwks();
    const ctxB = await setupJwks();
    const token = await signEs256(ctxB.privateKey, {
      sub: '00000000-0000-0000-0000-000000000004',
      aud: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    await expect(verifyJwtWithJwks(token, ctxA.jwks)).rejects.toThrow();
  });

  it('rejects payloads missing `sub`', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      // sub deliberately omitted
      aud: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    await expect(verifyJwtWithJwks(token, jwks)).rejects.toThrow();
  });

  it('rejects payloads where sub is not a UUID', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: 'not-a-uuid',
      aud: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    await expect(verifyJwtWithJwks(token, jwks)).rejects.toThrow();
  });

  it('accepts aud as either string or string[]', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000005',
      aud: ['authenticated', 'service'],
      role: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    const payload = await verifyJwtWithJwks(token, jwks);
    expect(payload.aud).toEqual(['authenticated', 'service']);
  });

  it('rejects tokens whose audience does not include authenticated', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000008',
      aud: 'service_role',
      role: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    await expect(verifyJwtWithJwks(token, jwks)).rejects.toThrow();
  });

  it('rejects tokens without the authenticated role', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000009',
      aud: 'authenticated',
      role: 'anon',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    await expect(verifyJwtWithJwks(token, jwks)).rejects.toThrow();
  });

  it('rejects tampered tokens (body changed after signing)', async () => {
    const { privateKey, jwks } = await setupJwks();
    const token = await signEs256(privateKey, {
      sub: '00000000-0000-0000-0000-000000000006',
      aud: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    });

    // Splice a different payload onto the same signature — jose must
    // detect the signature no longer covers this body.
    const [header, , signature] = token.split('.');
    const tamperedPayload = Buffer.from(
      JSON.stringify({
        sub: '00000000-0000-0000-0000-000000000007', // different uid
        aud: 'authenticated',
        exp: Math.floor(Date.now() / 1000) + 3600,
      }),
    ).toString('base64url');
    const tampered = `${header}.${tamperedPayload}.${signature}`;

    await expect(verifyJwtWithJwks(tampered, jwks)).rejects.toThrow();
  });
});
