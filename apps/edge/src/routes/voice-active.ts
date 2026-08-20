// Public read-only listing of active group voice calls — keyed off the
// `voice_active_calls` index the RoomVoiceDO maintains. The iOS message
// list polls this on tab focus to render a phone-icon badge on rows whose
// conversation has a live call.
//
// Not exposed per-conversation: the iOS message list cares about "which
// of the groups I'm in have a call right now?", one query for the whole
// page rather than one per row.

import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const voiceActiveRoutes = new Hono<AppBindings>();
voiceActiveRoutes.use('*', requireSession());

voiceActiveRoutes.get('/active', async (c) => {
  const supa = userClient(c.env, c.var.userJwt!);
  // RLS limits the view to conversations the caller participates in,
  // so the result set is already user-scoped — no extra filter needed.
  const { data, error } = await supa
    .from('voice_active_calls')
    .select('conversation_id, started_at, initiator_id');
  if (error) {
    console.warn('[voice/active] read failed', error);
    return jsonError(c, 502, 'voice_upstream_failed');
  }
  return c.json({ ok: true, active: data ?? [] });
});
