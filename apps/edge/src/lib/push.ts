import type { Env } from '../types';
import { serviceClient } from './supabase';
import { sendApns, type ApnsPayload } from './apns';

// Fan out a push to every active iOS device the user has registered.
// device_tokens.metadata.apns_env decides which APNS endpoint to hit
// ('dev' for TestFlight/Debug builds, 'prod' for App Store builds — same
// table, runtime routing).
//
// On Apple's "BadDeviceToken" / "Unregistered" responses, mark the token
// inactive so we stop hammering it. Other errors are logged-and-shrugged
// (transient).

// PRIVACY: do not embed message text, sender display name, or any other
// content the user might consider private in `payload.alert.body` or
// `.title`. iOS Notification Center retains the alert verbatim and shows
// it on the lock screen, where anyone with physical access can read it.
// The intended pattern (once a real caller arrives) is a generic alert
// ("New message" / "BotX replied") plus a structured extra object the
// app reads after unlock to fetch the actual content over HTTPS.
//
// See the audit follow-up: tightening this into a semantic `kind` enum
// belongs with the first product caller that wires push into a flow.
export interface NotifyUserInput {
  env: Env;
  userId: string;
  payload: ApnsPayload;
  collapseId?: string;
}

const RETIREMENT_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic']);

export async function notifyUser(input: NotifyUserInput): Promise<{ sent: number; failed: number }> {
  const { env, userId, payload, collapseId } = input;
  const supa = serviceClient(env);

  const { data: tokens, error } = await supa
    .from('device_tokens')
    .select('id, token, platform, metadata')
    .eq('user_id', userId)
    .eq('is_active', true);
  if (error) {
    console.warn('[push] device_tokens read failed', error);
    return { sent: 0, failed: 0 };
  }

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
        console.warn('[push] apns failed', { tokenId: row.id, status: result.status, reason: result.reason });
      }
    }),
  );

  return { sent, failed };
}

// Fan a "new message" push out to the human participants of a conversation,
// skipping the sender. Used for user_user DMs and group messages where the
// recipient set lives in conversation_participants. Fire-and-forget — call
// it through waitUntil so the HTTP response doesn't wait on APNS.
export async function notifyConversationUsers(input: {
  env: Env;
  conversationId: string;
  excludeUserId: string | null;
  payload: ApnsPayload;
  collapseId?: string;
}): Promise<void> {
  const { env, conversationId, excludeUserId, payload, collapseId } = input;
  const supa = serviceClient(env);
  const { data: rows, error } = await supa
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user');
  if (error) {
    console.warn('[push] participant read failed', error);
    return;
  }
  const recipients = (rows ?? [])
    .map((r) => r.participant_id as string)
    .filter((id) => id !== excludeUserId);
  await Promise.all(
    recipients.map((userId) => notifyUser({ env, userId, payload, collapseId })),
  );
}
