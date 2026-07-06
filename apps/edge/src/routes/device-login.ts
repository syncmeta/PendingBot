import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
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

export const deviceLoginRoutes = new Hono<AppBindings>();

type DbError = { message: string };
type DbResult<T> = Promise<{ data: T | null; error: DbError | null }>;
type UntypedDb = {
  from(table: string): {
    insert(row: Record<string, unknown>): Promise<{ error: DbError | null }>;
    select(columns: string): {
      eq(column: string, value: unknown): {
        maybeSingle(): DbResult<Record<string, unknown>>;
        eq(column: string, value: unknown): Promise<{ error: DbError | null }>;
      };
    };
    update(patch: Record<string, unknown>): {
      eq(column: string, value: unknown): {
        eq(column: string, value: unknown): Promise<{ error: DbError | null }>;
      } & Promise<{ error: DbError | null }>;
    };
  };
  rpc(fn: string, args: Record<string, unknown>): Promise<{ data: unknown; error: DbError | null }>;
};

function untypedDb(env: AppBindings['Bindings']): UntypedDb {
  return serviceClient(env) as unknown as UntypedDb;
}

const CreateChallengeBody = z.object({
  appKind: AppKind,
  deviceName: z.string().trim().min(1).max(120),
  devicePublicKey: z.string().trim().min(16).max(4096),
  scopes: z.array(Scope).default(['subject:read']),
  // Optional hint: which subject the requester wants to log in as. The
  // challenge creator is unauthenticated, so we do NOT verify permissions
  // here — we only record the hint. The PendingBot user who approves the
  // challenge sees this hint and, if non-null, MUST approve with the same
  // subjectId (enforced in /challenges/:id/approve). This blocks the
  // "trick the approver into signing for a different subject" attack.
  subjectId: z.string().uuid().optional(),
});

const ApproveChallengeBody = z.object({
  secret: z.string().trim().min(16).max(256),
  subjectId: z.string().uuid(),
  grantKind: GrantKind,
  scopes: z.array(Scope).default(['subject:read']),
});

const byteAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

function randomText(length: number): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byteAlphabet[byte % byteAlphabet.length]).join('');
}

function challengeCode(): string {
  return randomText(8).toUpperCase();
}

function normalizeStoredScopes(value: unknown): Set<string> {
  return new Set(Array.isArray(value) ? value.filter((scope): scope is string => typeof scope === 'string') : []);
}

function qrPayload(challengeId: string, secret: string, appKind: z.infer<typeof AppKind>): string {
  const query = new URLSearchParams({ s: secret, k: appKind });
  return `https://bot.pendingname.com/d/${challengeId}?${query.toString()}`;
}

function isExpired(expiresAt: string): boolean {
  return new Date(expiresAt).getTime() <= Date.now();
}

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

async function supabaseTokenHashForUser(env: AppBindings['Bindings'], userId: string): Promise<string | null> {
  const svc = serviceClient(env) as unknown as {
    auth?: {
      admin?: {
        getUserById?: (id: string) => Promise<{
          data?: { user?: { email?: string | null } | null } | null;
          error?: { message?: string } | null;
        }>;
        generateLink?: (params: { type: 'magiclink'; email: string }) => Promise<{
          data?: { properties?: { hashed_token?: string | null } | null } | null;
          error?: { message?: string } | null;
        }>;
      };
    };
  };
  const admin = svc.auth?.admin;
  if (!admin?.getUserById || !admin.generateLink) return null;

  const userResult = await admin.getUserById(userId);
  if (userResult.error) {
    console.error('auth.admin.getUserById failed', userResult.error.message);
    return null;
  }
  const email = userResult.data?.user?.email;
  if (!email) return null;

  const linkResult = await admin.generateLink({ type: 'magiclink', email });
  if (linkResult.error) {
    console.error('auth.admin.generateLink failed', linkResult.error.message);
    return null;
  }
  return linkResult.data?.properties?.hashed_token ?? null;
}

deviceLoginRoutes.post('/challenges', async (c) => {
  let parsed: z.infer<typeof CreateChallengeBody>;
  try {
    parsed = CreateChallengeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const id = crypto.randomUUID();
  const secret = randomToken('pdc');
  const code = challengeCode();
  const secretHash = await sha256Hex(secret);
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

  const svc = untypedDb(c.env);
  const { error } = await svc.from('subject_device_login_challenges').insert({
    id,
    challenge_secret_hash: secretHash,
    code,
    app_kind: parsed.appKind,
    platform: 'macos',
    device_name: parsed.deviceName,
    device_public_key: parsed.devicePublicKey,
    requested_scopes: parsed.scopes as Json,
    requested_subject_id: parsed.subjectId ?? null,
    status: 'pending',
    expires_at: expiresAt,
  });
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }

  return c.json({
    challengeId: id,
    secret,
    code,
    qrPayload: qrPayload(id, secret, parsed.appKind),
    expiresAt,
    status: 'pending',
  });
});

deviceLoginRoutes.get('/challenges/:id', async (c) => {
  const challengeId = c.req.param('id');
  const secret = c.req.query('secret') ?? c.req.query('s') ?? '';
  if (!secret) {
    return jsonError(c, 400, 'invalid_query', { message: 'missing secret' });
  }

  const svc = untypedDb(c.env);
  const { data: challenge, error } = await svc
    .from('subject_device_login_challenges')
    .select('id, challenge_secret_hash, app_kind, platform, device_name, device_public_key, requested_scopes, requested_subject_id, status, approved_subject_id, approved_by_user_id, grant_kind, issued_grant_id, expires_at')
    .eq('id', challengeId)
    .maybeSingle();
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  if (!challenge) return jsonError(c, 404, 'not_found');

  const secretHash = await sha256Hex(secret);
  if (secretHash !== challenge.challenge_secret_hash) {
    return jsonError(c, 403, 'forbidden', { message: 'invalid secret' });
  }

  if ((challenge.status === 'pending' || challenge.status === 'approved') && isExpired(String(challenge.expires_at))) {
    await svc.from('subject_device_login_challenges').update({ status: 'expired' }).eq('id', challengeId);
    return c.json({ status: 'expired', deviceGrantToken: null });
  }

  if (challenge.status !== 'approved') {
    return c.json({ status: challenge.status, deviceGrantToken: null });
  }

  const grantToken = randomToken('pdg');
  const grantId = crypto.randomUUID();
  const tokenHash = await sha256Hex(grantToken);
  const { data: grant, error: consumeErr } = await svc.rpc('consume_subject_device_login_challenge', {
    p_challenge_id: challengeId,
    p_challenge_secret_hash: secretHash,
    p_grant_id: grantId,
    p_token_hash: tokenHash,
  });
  if (consumeErr) {
    const message = rpcMessage(consumeErr);
    if (/expired/i.test(message)) return jsonError(c, 410, 'session_expired', { message });
    if (/not approved/i.test(message)) return jsonError(c, 409, 'conflict', { message });
    if (/invalid secret|forbidden/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  const grantRow = grant && typeof grant === 'object' ? grant as Record<string, unknown> : {};
  const scopes = Array.isArray(grantRow.scopes) ? grantRow.scopes : [];

  // Best-effort: mint a per-user family SSO credential for the approving
  // user and hand it back so the app can stash it in the shared keychain
  // group for future silent logins (POST /device-grant/mint). The consume
  // RPC surfaces the approver via `granted_by_user_id`. If minting fails we
  // log and continue — a missing family credential must never fail a login
  // the device grant already succeeded for.
  let familyCredential: string | null = null;
  // 批准者的展示名 + 头像 seed —— 随凭据一起下发，PendingCrew 存进共享
  // keychain 的家族凭据里，侧栏身份区在 /v1/me/subject 拉回来之前就能显示
  // 真实身份（而不是"已登录"占位 + 错头像）。best-effort，取不到不挡登录。
  let displayName: string | null = null;
  let avatarSeed: string | null = null;
  const grantedByUserId = typeof grantRow.granted_by_user_id === 'string' ? grantRow.granted_by_user_id : '';
  if (grantedByUserId) {
    // 链式多 .eq 超出本文件 UntypedDb 的窄类型 —— 这两条读走带类型的 client。
    const typed = serviceClient(c.env);
    const [{ data: personal }, { data: userRow }] = await Promise.all([
      typed.from('subjects')
        .select('display_name')
        .eq('kind', 'user_account')
        .eq('user_id', grantedByUserId)
        .eq('status', 'active')
        .maybeSingle(),
      typed.from('users').select('custom_fields').eq('id', grantedByUserId).maybeSingle(),
    ]);
    displayName = typeof personal?.display_name === 'string' ? personal.display_name : null;
    const cf = (userRow?.custom_fields ?? null) as Record<string, unknown> | null;
    avatarSeed = typeof cf?.avatar_seed === 'string' && cf.avatar_seed.length > 0
      ? cf.avatar_seed
      : grantedByUserId;
    const deviceName = typeof grantRow.device_name === 'string' && grantRow.device_name.length > 0
      ? grantRow.device_name
      : 'Mac';
    const famToken = randomToken('pfa');
    const famId = crypto.randomUUID();
    const { error: famErr } = await svc.rpc('issue_family_sso_credential', {
      p_id: famId,
      p_user_id: grantedByUserId,
      p_token_hash: await sha256Hex(famToken),
      p_device_name: deviceName,
    });
    if (famErr) {
      console.error('issue_family_sso_credential failed', rpcMessage(famErr));
    } else {
      familyCredential = famToken;
    }
  }

  return c.json({
    status: 'approved',
    deviceGrantToken: grantToken,
    supabaseTokenHash: challenge.app_kind === 'pendingbot_macos' && grantedByUserId
      ? await supabaseTokenHashForUser(c.env, grantedByUserId)
      : null,
    grantId: typeof grantRow.grant_id === 'string' ? grantRow.grant_id : grantId,
    subjectId: typeof grantRow.subject_id === 'string' ? grantRow.subject_id : null,
    grantKind: typeof grantRow.grant_kind === 'string' ? grantRow.grant_kind : null,
    scopes,
    familyCredential,
    displayName,
    avatarSeed,
  });
});

deviceLoginRoutes.post('/challenges/:id/approve', requireSession(), async (c) => {
  const challengeId = c.req.param('id');
  const userId = c.var.userId!;
  let parsed: z.infer<typeof ApproveChallengeBody>;
  try {
    parsed = ApproveChallengeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const svc = untypedDb(c.env);
  const { data: challenge, error } = await svc
    .from('subject_device_login_challenges')
    .select('id, challenge_secret_hash, app_kind, requested_scopes, requested_subject_id, status, expires_at')
    .eq('id', challengeId)
    .maybeSingle();
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  if (!challenge) return jsonError(c, 404, 'not_found');

  const secretHash = await sha256Hex(parsed.secret);
  if (secretHash !== challenge.challenge_secret_hash) {
    return jsonError(c, 403, 'forbidden', { message: 'invalid secret' });
  }
  if (challenge.status !== 'pending') {
    return jsonError(c, 409, 'conflict', { detail: { status: challenge.status } });
  }
  if (isExpired(String(challenge.expires_at))) {
    await svc.from('subject_device_login_challenges').update({ status: 'expired' }).eq('id', challengeId);
    return jsonError(c, 410, 'session_expired', { message: 'challenge expired' });
  }
  if (!appGrantCompatible(challenge.app_kind as z.infer<typeof AppKind>, parsed.grantKind)) {
    return jsonError(c, 400, 'invalid_body', { message: 'grant kind does not match app kind' });
  }
  // Anti-spoof: if the requester pinned a subject at challenge-creation
  // time, the approver must approve with that same subject. Otherwise an
  // attacker could swap "I want to log in as my personal account" into
  // "approver signs me in as their group account".
  const requestedSubject = challenge.requested_subject_id;
  if (typeof requestedSubject === 'string' && requestedSubject !== parsed.subjectId) {
    return jsonError(c, 409, 'subject_mismatch', {
      message: 'challenge was created for a different subject',
      detail: { requestedSubjectId: requestedSubject },
    });
  }
  const allowedScopes = allowedScopesForGrant(parsed.grantKind);
  if (!scopesSubsetOf(parsed.scopes, allowedScopes)) {
    return jsonError(c, 400, 'invalid_body', { message: 'requested scopes exceed grant kind' });
  }
  const originalScopes = normalizeStoredScopes(challenge.requested_scopes);
  if (!scopesSubsetOf(parsed.scopes, originalScopes)) {
    return jsonError(c, 400, 'invalid_body', { message: 'approved scopes exceed original challenge request' });
  }

  const { data: allowed, error: allowedErr } = await svc.rpc('subject_can_authorize_device_grant', {
    p_subject_id: parsed.subjectId,
    p_user_id: userId,
    p_grant_kind: parsed.grantKind,
  });
  if (allowedErr) return jsonError(c, 500, 'database_error', { detail: allowedErr.message });
  if (allowed !== true) return jsonError(c, 403, 'forbidden');

  if (challenge.app_kind === 'pendingbot_macos') {
    const { data: subject, error: subjectErr } = await svc
      .from('subjects')
      .select('id, kind, user_id')
      .eq('id', parsed.subjectId)
      .maybeSingle();
    if (subjectErr) return jsonError(c, 500, 'database_error', { detail: subjectErr.message });
    if (!subject || subject.kind !== 'user_account' || subject.user_id !== userId) {
      return jsonError(c, 403, 'forbidden', {
        message: 'PendingBot Mac login must use the approving user account',
      });
    }
  }

  const { error: updateErr } = await svc
    .from('subject_device_login_challenges')
    .update({
      status: 'approved',
      approved_subject_id: parsed.subjectId,
      approved_by_user_id: userId,
      grant_kind: parsed.grantKind,
      requested_scopes: parsed.scopes as Json,
      approved_at: new Date().toISOString(),
    })
    .eq('id', challengeId)
    .eq('status', 'pending');
  if (updateErr) return jsonError(c, 500, 'database_error', { detail: updateErr.message });

  return c.json({ ok: true, status: 'approved' });
});
