import { SignJWT, importPKCS8 } from 'jose';
import type { Env } from '../types';

// APNS push using token-based auth.
//
// Per-environment p8 keys (Apple's recommendation, two keys for blast-radius
// isolation): APNS_KEY_DEV signs JWTs that target api.sandbox.push.apple.com,
// APNS_KEY_PROD targets api.push.apple.com. Same Team ID, same topic
// (bundle id) — only the signing key + endpoint differ.
//
// JWTs live up to 1 hour; we cache the signed token per-isolate to avoid
// re-signing on every push (signing is ~5ms but adds up under fan-out).

interface CachedToken {
  jwt: string;
  expiresAt: number; // ms epoch
}
const TOKEN_CACHE = new Map<'dev' | 'prod', CachedToken>();
// Refresh well before Apple's 1-hour ceiling to dodge clock skew between
// Workers isolates (no monotonic clock) and Apple's edge — a stale JWT
// gets a 403 ExpiredProviderToken and forces every push in the burst to
// retry. 45min leaves 15min of headroom in both directions.
const TOKEN_TTL_MS = 45 * 60 * 1000;

async function signApnsToken(
  env: Env,
  envKind: 'dev' | 'prod',
): Promise<string> {
  const cached = TOKEN_CACHE.get(envKind);
  if (cached && cached.expiresAt > Date.now()) return cached.jwt;

  const pem = envKind === 'dev' ? env.APNS_KEY_DEV : env.APNS_KEY_PROD;
  const kid = envKind === 'dev' ? env.APNS_KEY_ID_DEV : env.APNS_KEY_ID_PROD;
  const key = await importPKCS8(pem, 'ES256');
  const now = Math.floor(Date.now() / 1000);
  const jwt = await new SignJWT({ iss: env.APNS_TEAM_ID, iat: now })
    .setProtectedHeader({ alg: 'ES256', kid })
    .sign(key);
  TOKEN_CACHE.set(envKind, { jwt, expiresAt: Date.now() + TOKEN_TTL_MS });
  return jwt;
}

export interface ApnsPayload {
  // Standard alert payload. Localizable variants (loc-key etc.) can be added
  // by passing them through `extra` — they live alongside `aps`.
  alert?: { title?: string; body?: string };
  badge?: number;
  sound?: string | 'default';
  threadId?: string;          // collapses notifications in the same thread
  category?: string;          // for action buttons
  contentAvailable?: boolean; // background push (silent)
  mutableContent?: boolean;   // notification service extension
  // Free-form top-level fields. Apple reserves only `aps`; anything else
  // lands alongside it for the app to inspect. Used for typed payloads
  // (e.g. { kind: 'voice_ring', conversation_id, from_user_id }).
  extra?: Record<string, unknown>;
}

export interface SendApnsInput {
  env: Env;
  deviceToken: string;
  apnsEnv: 'dev' | 'prod';
  payload: ApnsPayload;
  // Push type — 'alert' = visible, 'background' = silent, 'voip' = PushKit
  // VoIP push (must target the .voip topic suffix; receiver MUST hand it
  // to CallKit immediately or Apple revokes VoIP privileges).
  pushType?: 'alert' | 'background' | 'voip';
  // Override the default APNs topic. Defaults to `env.APNS_TOPIC` (the app
  // bundle id). VoIP pushes set this to `<bundle>.voip` — Apple routes
  // them through a distinct pipeline keyed off the topic suffix.
  topic?: string;
  collapseId?: string;        // dedup similar notifications server-side
  expiration?: number;        // unix ts; 0 = drop if not deliverable now
}

export interface SendApnsResult {
  ok: boolean;
  status: number;
  apnsId?: string;
  reason?: string; // Apple's machine-readable error code (e.g. BadDeviceToken)
}

export async function sendApns(input: SendApnsInput): Promise<SendApnsResult> {
  const { env, deviceToken, apnsEnv, payload, pushType = 'alert' } = input;

  const host = apnsEnv === 'dev' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  const jwt = await signApnsToken(env, apnsEnv);

  const aps: Record<string, unknown> = {};
  if (payload.alert) aps.alert = payload.alert;
  if (payload.badge !== undefined) aps.badge = payload.badge;
  if (payload.sound !== undefined) aps.sound = payload.sound;
  if (payload.threadId) aps['thread-id'] = payload.threadId;
  if (payload.category) aps.category = payload.category;
  if (payload.contentAvailable) aps['content-available'] = 1;
  if (payload.mutableContent) aps['mutable-content'] = 1;

  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    'apns-topic': input.topic ?? env.APNS_TOPIC,
    'apns-push-type': pushType,
  };
  // VoIP pushes have a strict deadline (Apple drops them after a few
  // seconds if not deliverable). Mark high priority so they don't get
  // queued behind a backlog of alert pushes — alert defaults are good
  // enough for the visible-banner path.
  if (pushType === 'voip') headers['apns-priority'] = '10';
  if (input.collapseId) headers['apns-collapse-id'] = input.collapseId;
  if (input.expiration !== undefined) headers['apns-expiration'] = String(input.expiration);

  // Custom keys ride as top-level siblings of `aps` (APNs convention).
  const body: Record<string, unknown> = { aps };
  if (payload.extra) {
    for (const [k, v] of Object.entries(payload.extra)) {
      if (k === 'aps') continue; // aps is reserved
      body[k] = v;
    }
  }

  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (res.status === 200) {
    return { ok: true, status: 200, apnsId: res.headers.get('apns-id') ?? undefined };
  }
  let reason: string | undefined;
  try {
    const body = (await res.json()) as { reason?: string };
    reason = body.reason;
  } catch {
    /* non-json body — ignore */
  }
  return { ok: false, status: res.status, reason };
}
