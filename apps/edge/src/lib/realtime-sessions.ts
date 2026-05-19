// Realtime voice-call session bookkeeping. Backed by
// pendingbot.realtime_sessions (see migration 20260512042509). Holds the
// immutable binding session_id ↔ (user, conversation, bot) so /attach,
// /summary, /end can't be replayed across sessions or used after
// the call has been declared ended.
//
// Why a server-side hard cap exists at all: OpenAI's ephemeral
// client_secret TTL only controls connect initiation, not the
// post-connect session's runtime. Without our own cap a client that
// stays connected indefinitely keeps consuming tokens and billing. The
// cap below is generous (30 min) — typical voice chats are minutes,
// not hours.

import { serviceClient } from './supabase';
import type { Env } from '../types';

// Max wall-clock time between /session mint and the latest /attach or
// /summary call. Past this, the session is treated as ended even
// if /end never arrived (call hung up uncleanly, app crashed, etc).
// Tune in one place if real call patterns demand it.
export const REALTIME_SESSION_MAX_AGE_MS = 30 * 60 * 1000;

export interface RealtimeSession {
  session_id: string;
  user_id: string;
  conversation_id: string;
  bot_id: string;
  created_at: string;
  ended_at: string | null;
  openai_session_id: string | null;
}

export type RequireSessionResult =
  | { ok: true; session: RealtimeSession }
  | { ok: false; status: 401 | 403 | 410; body: { error: string; message?: string } };

/**
 * Look up a realtime session by id and assert it's still valid for the
 * caller. Used by /attach, /summary, /end. Returns either the session
 * row or a ready-to-return error response.
 *
 *   ok: false, status: 401 — session does not exist
 *   ok: false, status: 403 — session exists but belongs to a different user
 *   ok: false, status: 410 — session is closed or older than the hard cap
 */
export async function requireActiveSession(
  env: Env,
  sessionId: string,
  callerUserId: string,
): Promise<RequireSessionResult> {
  const supa = serviceClient(env);
  const { data, error } = await supa
    .from('realtime_sessions')
    .select('session_id, user_id, conversation_id, bot_id, created_at, ended_at, openai_session_id')
    .eq('session_id', sessionId)
    .maybeSingle();

  if (error) {
    console.warn('[realtime-sessions] read failed', error.message);
    return { ok: false, status: 401, body: { error: 'session_not_found' } };
  }
  if (!data) {
    return { ok: false, status: 401, body: { error: 'session_not_found' } };
  }

  const session: RealtimeSession = data;

  if (session.user_id !== callerUserId) {
    return {
      ok: false,
      status: 403,
      body: { error: 'session_forbidden' },
    };
  }

  if (session.ended_at) {
    return {
      ok: false,
      status: 410,
      body: { error: 'session_ended' },
    };
  }

  const ageMs = Date.now() - new Date(session.created_at).getTime();
  if (ageMs > REALTIME_SESSION_MAX_AGE_MS) {
    // Auto-close: mark the row ended so future calls converge on
    // session_ended instead of dragging the timestamp comparison out.
    // Fire-and-forget; if the update fails we still reject this call.
    void supa
      .from('realtime_sessions')
      .update({ ended_at: new Date().toISOString() })
      .eq('session_id', sessionId)
      .is('ended_at', null)
      .then(({ error: updErr }) => {
        if (updErr) console.warn('[realtime-sessions] auto-close failed', updErr.message);
      });
    return {
      ok: false,
      status: 410,
      body: { error: 'session_expired' },
    };
  }

  return { ok: true, session };
}

/**
 * Record a freshly-minted session. Called from /v1/realtime/session
 * AFTER the OpenAI client_secret comes back successfully — we want a
 * row in realtime_sessions iff the iOS client could actually use this
 * session_id.
 */
export async function recordRealtimeSession(
  env: Env,
  row: {
    session_id: string;
    user_id: string;
    conversation_id: string;
    bot_id: string;
    openai_session_id?: string | null;
  },
): Promise<void> {
  const supa = serviceClient(env);
  const { error } = await supa
    .from('realtime_sessions')
    .insert({
      session_id: row.session_id,
      user_id: row.user_id,
      conversation_id: row.conversation_id,
      bot_id: row.bot_id,
      openai_session_id: row.openai_session_id ?? null,
    });
  if (error) {
    // Don't fail the user's call over a bookkeeping failure — the
    // session will simply lack server-side replay protection, which is
    // a regression but not user-facing. Surface the error in logs so
    // ops notices.
    console.warn('[realtime-sessions] insert failed', error.message);
  }
}

/**
 * Mark a session ended. Idempotent — calling twice is fine. Called from
 * /v1/realtime/end and from requireActiveSession's auto-close path.
 */
export async function endRealtimeSession(env: Env, sessionId: string): Promise<void> {
  const supa = serviceClient(env);
  const { error } = await supa
    .from('realtime_sessions')
    .update({ ended_at: new Date().toISOString() })
    .eq('session_id', sessionId)
    .is('ended_at', null);
  if (error) {
    console.warn('[realtime-sessions] end failed', error.message);
  }
}

// Realtime function tool that lets a 1:1 voice bot hang up the call
// itself. Declared in the OpenAI session config (the WebRTC mint body
// and the WebSocket-transport session.update alike). The worker is not
// on the 1:1 audio path, so iOS watches for this function call and ends
// the call when the bot invokes it.
export const REALTIME_HANG_UP_TOOL = {
  type: 'function',
  name: 'hang_up',
  description:
    'Hang up (end) this voice call. Call this when the user asks you ' +
    'to hang up, or when the conversation has clearly finished.',
  parameters: { type: 'object', properties: {}, additionalProperties: false },
} as const;
