-- Realtime voice-call session bindings.
--
-- Why this table exists:
-- The /v1/realtime/session route generates a `session_id = randomUUID()`
-- (PendingBot's own id, distinct from OpenAI's `sess_…`) and hands it to
-- iOS. Subsequent /v1/realtime/{usage,transcripts,end} calls then carry
-- the session_id along with conversation_id, bot_id, etc — and prior to
-- this migration the worker re-derived those from the request body. That
-- meant:
--   • a leaked / guessed session_id could be reused after /end ("replay")
--   • no server-side cap on call duration (per OpenAI docs the ephemeral
--     client_secret TTL controls connect *initiation* only, not the
--     post-connect session)
-- Bind the session_id immutably to (user, conversation, bot) at mint
-- time, gate subsequent calls on that binding, and reject anything
-- whose row is missing / belongs to another user / already ended /
-- older than the hard cap.

BEGIN;

CREATE TABLE IF NOT EXISTS pendingbot.realtime_sessions (
  session_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  bot_id uuid NOT NULL REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  -- Raw OpenAI session id (sess_...) if we capture it from the mint
  -- response — kept for debugging cross-references against OpenAI's
  -- side, not used for auth.
  openai_session_id text
);

-- Look up by session_id is the hot path (every /usage + /transcripts).
-- The PRIMARY KEY index already covers that. Add a (user_id, created_at)
-- index for the future "list my recent calls" endpoint.
CREATE INDEX IF NOT EXISTS idx_realtime_sessions_user_time
  ON pendingbot.realtime_sessions (user_id, created_at DESC);

ALTER TABLE pendingbot.realtime_sessions ENABLE ROW LEVEL SECURITY;

-- Read your own sessions (will power a future "calls history" view).
-- Writes go through the worker with service role; deliberately no
-- INSERT/UPDATE/DELETE policy.
DROP POLICY IF EXISTS realtime_sessions_self_read
  ON pendingbot.realtime_sessions;
CREATE POLICY realtime_sessions_self_read
  ON pendingbot.realtime_sessions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

COMMIT;
