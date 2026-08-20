import type { Env } from '../types';
import { serviceClient } from './supabase';
import { sendApns, type ApnsPayload } from './apns';

// Fan out a push to every active iOS device the user has registered.
// device_tokens.metadata.apns_env decides which APNS endpoint to hit
// ('dev' for TestFlight/Debug builds, 'prod' for App Store builds — same
// table, runtime routing).
//
// Two layers:
//   - notifyUser({ payload, ... })          → raw send, caller owns the
//                                              alert body verbatim. Use
//                                              this for non-message pushes
//                                              (voice rings etc.).
//   - notifyUserMessage({ senderName, ... }) → message-shaped push that
//                                              renders the alert body
//                                              against the recipient's
//                                              notification_preview_mode
//                                              preference (generic / name /
//                                              name_content).
//
// On Apple's "BadDeviceToken" / "Unregistered" responses, mark the token
// inactive so we stop hammering it. Other errors are logged-and-shrugged
// (transient).

export type NotificationPreviewMode = 'generic' | 'name' | 'name_content';

const PREVIEW_MAX_LEN = 60;
const GENERIC_ALERT = '新消息';

function normalizePreviewMode(v: unknown): NotificationPreviewMode {
  return v === 'name' || v === 'name_content' ? v : 'generic';
}

// Single source of truth for what users see on the lock screen. Anything
// above 'generic' opts the user into surfacing names / message text — the
// caller's job is to feed in clean, untrimmed values; this fn handles the
// truncation + fallback chain.
export function renderAlertBody(
  mode: NotificationPreviewMode,
  senderName: string | null,
  contentPreview: string | null,
): string {
  if (mode === 'name' && senderName) return senderName;
  if (mode === 'name_content') {
    const name = senderName ?? GENERIC_ALERT;
    const raw = (contentPreview ?? '').replace(/\s+/g, ' ').trim();
    if (!raw) return name;
    const body = raw.length > PREVIEW_MAX_LEN ? raw.slice(0, PREVIEW_MAX_LEN) + '…' : raw;
    return `${name}：${body}`;
  }
  return GENERIC_ALERT;
}

const RETIREMENT_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic']);

interface SendToTokensInput {
  env: Env;
  userId: string;
  payload: ApnsPayload;
  collapseId?: string;
  // Which kind of device_tokens row to target. 'apns' = standard alert /
  // background pushes (default, matches the historical fan-out behaviour);
  // 'voip' = PushKit VoIP push for CallKit-incoming voice_ring. The two
  // are stored as separate rows since Apple mints distinct tokens per
  // registry and the topic/push-type differ.
  kind?: 'apns' | 'voip';
}

// Internal — caller has already decided exactly what alert text to ship.
async function sendToTokens(input: SendToTokensInput): Promise<{ sent: number; failed: number }> {
  const { env, userId, payload, collapseId } = input;
  const kind = input.kind ?? 'apns';
  const supa = serviceClient(env);

  const { data: tokens, error } = await supa
    .from('device_tokens')
    .select('id, token, platform, metadata')
    .eq('user_id', userId)
    .eq('is_active', true)
    .eq('kind', kind);
  if (error) {
    console.warn('[push] device_tokens read failed', error);
    return { sent: 0, failed: 0 };
  }

  // For VoIP, target the `.voip` topic suffix and flag the push-type so
  // Apple routes it through PushKit (and the receiver is allowed —
  // required, actually — to call CallKit's reportNewIncomingCall on it).
  const isVoip = kind === 'voip';
  const topic = isVoip ? `${env.APNS_TOPIC}.voip` : undefined;

  let sent = 0;
  let failed = 0;
  await Promise.all(
    (tokens ?? []).map(async (row) => {
      if (row.platform !== 'ios') return; // web/android out of scope here
      const meta = (row.metadata ?? {}) as Record<string, unknown>;
      const apnsEnv: 'dev' | 'prod' = meta.apns_env === 'prod' ? 'prod' : 'dev';
      const result = await sendApns({
        env,
        deviceToken: row.token,
        apnsEnv,
        payload,
        collapseId,
        pushType: isVoip ? 'voip' : 'alert',
        topic,
      });
      if (result.ok) {
        sent++;
        await supa
          .from('device_tokens')
          .update({ last_used_at: new Date().toISOString() })
          .eq('id', row.id);
      } else {
        failed++;
        if (result.reason && RETIREMENT_REASONS.has(result.reason)) {
          await supa
            .from('device_tokens')
            .update({ is_active: false })
            .eq('id', row.id);
        }
        console.warn('[push] apns failed', {
          tokenId: row.id,
          status: result.status,
          reason: result.reason,
        });
      }
    }),
  );

  return { sent, failed };
}

export interface NotifyUserInput {
  env: Env;
  userId: string;
  payload: ApnsPayload;
  collapseId?: string;
}

// Raw, caller-controlled body. Used by typed notifications whose copy is
// fixed at the call site (not voice_ring — that goes through
// `sendVoipRing` to PushKit).
export async function notifyUser(input: NotifyUserInput): Promise<{ sent: number; failed: number }> {
  return sendToTokens(input);
}

// PushKit VoIP delivery — fan out to every active VoIP token the user
// has registered. iOS 13+ contract: the receiving app must call
// CXProvider.reportNewIncomingCall the moment the push lands, or Apple
// revokes VoIP push privileges for the app. That means VoIP push is
// reserved for inputs that **will** produce an incoming-call screen —
// don't reuse this for arbitrary background work. Payload body sits
// alongside `aps` (PushKit hands the whole top-level dict to the app).
export async function sendVoipRing(input: {
  env: Env;
  userId: string;
  payload: ApnsPayload;
  collapseId?: string;
}): Promise<{ sent: number; failed: number }> {
  return sendToTokens({ ...input, kind: 'voip' });
}

export interface NotifyUserMessageInput {
  env: Env;
  userId: string;
  // Sender display name as it should appear in the alert body. Pass the
  // bot's display_name for bot replies, the user's display_name for human
  // messages. null disables name-mode rendering (alert falls back to the
  // generic copy).
  senderName: string | null;
  // Untrimmed message text. Trimming + truncation happen inside the
  // renderer. Pass null for non-textual notifications.
  contentPreview: string | null;
  // Custom keys to ride alongside aps (e.g. { conversationId, kind }).
  extra?: Record<string, unknown>;
  threadId?: string;
  collapseId?: string;
}

// Message-shaped push — renders the alert body against the recipient's
// notification_preview_mode preference, then sends to all their devices.
export async function notifyUserMessage(
  input: NotifyUserMessageInput,
): Promise<{ sent: number; failed: number }> {
  const { env, userId, senderName, contentPreview, extra, threadId, collapseId } = input;
  const supa = serviceClient(env);
  const { data: prefRow } = await supa
    .from('users')
    .select('custom_fields')
    .eq('id', userId)
    .maybeSingle();
  const cf = (prefRow?.custom_fields ?? null) as Record<string, unknown> | null;
  const mode = normalizePreviewMode(cf?.notification_preview_mode);
  const body = renderAlertBody(mode, senderName, contentPreview);
  return sendToTokens({
    env,
    userId,
    payload: {
      alert: { body },
      sound: 'default',
      threadId,
      extra,
    },
    collapseId,
  });
}

// Fan a message-shaped push out to the human participants of a conversation,
// skipping the sender. Used for user_user DMs and group messages where the
// recipient set lives in conversation_participants. Fire-and-forget — call
// it through waitUntil so the HTTP response doesn't wait on APNS.
export async function notifyConversationUsers(input: {
  env: Env;
  conversationId: string;
  excludeUserId: string | null;
  senderName: string | null;
  contentPreview: string | null;
  extra?: Record<string, unknown>;
  threadId?: string;
  collapseId?: string;
}): Promise<void> {
  const { env, conversationId, excludeUserId, ...passthrough } = input;
  const supa = serviceClient(env);
  const { data: rows, error } = await supa
    .from('conversation_participants')
    .select('participant_id, muted')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user');
  if (error) {
    console.warn('[push] participant read failed', error);
    return;
  }
  const recipients = (rows ?? [])
    .filter((r) => !r.muted)
    .map((r) => r.participant_id as string)
    .filter((id) => id !== excludeUserId);
  await Promise.all(
    recipients.map((userId) => notifyUserMessage({ env, userId, ...passthrough })),
  );
}
