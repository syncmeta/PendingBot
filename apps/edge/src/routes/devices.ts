import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const deviceRoutes = new Hono<AppBindings>();
deviceRoutes.use('*', requireSession());

const RegisterBody = z.object({
  platform: z.enum(['ios', 'web', 'android']),
  token: z.string().min(8).max(512),
  // iOS only: which APNS environment (TestFlight/Debug=dev, App Store=prod).
  // The client reports this from build flags so we route correctly.
  apnsEnv: z.enum(['dev', 'prod']).optional(),
  // iOS only: distinguish a standard APNs token from a PushKit VoIP token.
  // Each install registers both (separate tokens, separate rows). Web /
  // android only ever send 'apns' or omit it — the default covers them.
  kind: z.enum(['apns', 'voip']).optional(),
  endpoint: z.string().url().optional(), // web push endpoint
});

// POST /v1/devices/register — idempotent on (user_id, token).
deviceRoutes.post('/register', async (c) => {
  const userId = c.var.userId!;
  let parsed: z.infer<typeof RegisterBody>;
  try {
    parsed = RegisterBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = serviceClient(c.env);
  const metadata = parsed.apnsEnv ? { apns_env: parsed.apnsEnv } : {};

  const { error } = await supa.from('device_tokens').upsert(
    {
      user_id: userId,
      platform: parsed.platform,
      token: parsed.token,
      endpoint: parsed.endpoint,
      metadata,
      kind: parsed.kind ?? 'apns',
      is_active: true,
      last_used_at: new Date().toISOString(),
    },
    { onConflict: 'user_id,token' },
  );
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ ok: true });
});

const UnregisterBody = z.object({ token: z.string().min(8).max(512) });

// POST /v1/devices/unregister — flip is_active=false.
deviceRoutes.post('/unregister', async (c) => {
  const userId = c.var.userId!;
  let body: z.infer<typeof UnregisterBody>;
  try {
    body = UnregisterBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const supa = serviceClient(c.env);
  const { error } = await supa
    .from('device_tokens')
    .update({ is_active: false })
    .eq('user_id', userId)
    .eq('token', body.token);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ ok: true });
});
