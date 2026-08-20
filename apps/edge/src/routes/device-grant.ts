import { Hono } from 'hono';
import { z } from 'zod';
import { serviceClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import {
  AppKind,
  GrantKind,
  Scope,
  sha256Hex,
  randomToken,
  appGrantCompatible,
  allowedScopesForGrant,
  scopesSubsetOf,
} from '../lib/device-grant-scopes';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';

export const deviceGrantRoutes = new Hono<AppBindings>();

const MintBody = z.object({
  subjectId: z.string().uuid(),
  grantKind: GrantKind,
  scopes: z.array(Scope).default(['subject:read']),
  appKind: AppKind,
  deviceName: z.string().trim().min(1).max(120),
  devicePublicKey: z.string().trim().min(16).max(4096),
});

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

// Family-SSO credential → scoped device grant.
//
// The caller presents a per-user `pfa_*` family token (from the shared
// keychain group) instead of a full session. We hash it and hand the hash
// to `mint_device_grant_from_family`, which validates the credential,
// re-checks `subject_can_authorize_device_grant`, and inserts the grant —
// so the app never holds the user's session, only a credential scoped to
// what this grant kind allows.
deviceGrantRoutes.post('/mint', async (c) => {
  const auth = c.req.header('authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
  const token = match?.[1]?.trim();
  if (!token || !token.startsWith('pfa_')) {
    return jsonError(c, 401, 'unauthorized', { message: 'missing family credential' });
  }

  let parsed: z.infer<typeof MintBody>;
  try {
    parsed = MintBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  if (!appGrantCompatible(parsed.appKind, parsed.grantKind)) {
    return jsonError(c, 400, 'invalid_body', { message: 'grant kind does not match app kind' });
  }
  if (!scopesSubsetOf(parsed.scopes, allowedScopesForGrant(parsed.grantKind))) {
    return jsonError(c, 400, 'invalid_body', { message: 'requested scopes exceed grant kind' });
  }

  const familyHash = await sha256Hex(token);
  const grantToken = randomToken('pdg');
  const grantId = crypto.randomUUID();
  const tokenHash = await sha256Hex(grantToken);

  const { data: row, error } = await serviceClient(c.env).rpc('mint_device_grant_from_family', {
    p_family_token_hash: familyHash,
    p_grant_id: grantId,
    p_token_hash: tokenHash,
    p_subject_id: parsed.subjectId,
    p_grant_kind: parsed.grantKind,
    p_scopes: parsed.scopes as Json,
    p_app_kind: parsed.appKind,
    p_device_name: parsed.deviceName,
    p_device_public_key: parsed.devicePublicKey,
  });
  if (error) {
    const message = rpcMessage(error);
    if (/not authorized/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found|inactive/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  const grantRow = row && typeof row === 'object' ? row as Record<string, unknown> : {};
  const scopes = Array.isArray(grantRow.scopes) ? grantRow.scopes : parsed.scopes;

  return c.json({
    deviceGrantToken: grantToken,
    grantId,
    subjectId: parsed.subjectId,
    grantKind: parsed.grantKind,
    scopes,
  });
});
