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
