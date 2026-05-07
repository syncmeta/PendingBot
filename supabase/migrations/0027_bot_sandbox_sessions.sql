-- Per-conversation Daytona sandbox tracking. The chat agent's execute_code
-- tool lazily creates one Daytona sandbox per conversation and reuses it
-- across turns; this table is the lookup index + idle-cleanup target.
--
-- Lifecycle:
--   1. First execute_code call in a conversation:
--        POST /api/sandbox  →  insert row with daytona_sandbox_id, bootstrapped=false
--        run pip install <common pkgs>  →  UPDATE bootstrapped=true
--        run user code  →  UPDATE last_used_at=now()
--   2. Subsequent calls: SELECT row, run code, UPDATE last_used_at
--   3. Cron sweep: rows with last_used_at < now() - 1h get
--        DELETE /api/sandbox/{id}  +  DELETE FROM bot_sandbox_sessions
--   4. Conversation deletion CASCADES, leaving an orphan Daytona sandbox
--      until the next cron sweep — acceptable, the cron is the source of
--      truth for cleanup.
--
-- Service role only — no end-user client touches this table directly.

BEGIN;

CREATE TABLE pendingbot.bot_sandbox_sessions (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    daytona_sandbox_id text NOT NULL,
    bootstrapped boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bot_sandbox_sessions_pkey PRIMARY KEY (id),
    CONSTRAINT bot_sandbox_sessions_conversation_uniq UNIQUE (conversation_id),
    CONSTRAINT bot_sandbox_sessions_conversation_id_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE
);
ALTER TABLE pendingbot.bot_sandbox_sessions OWNER TO postgres;

-- Cron sweep predicate: last_used_at < threshold. Index covers it directly.
CREATE INDEX idx_sandbox_sessions_last_used
  ON pendingbot.bot_sandbox_sessions(last_used_at);

ALTER TABLE pendingbot.bot_sandbox_sessions ENABLE ROW LEVEL SECURITY;
-- No policies = no client access. service_role bypasses RLS for the
-- edge worker, which is the only intended writer/reader.

GRANT SELECT, INSERT, DELETE, UPDATE
  ON TABLE pendingbot.bot_sandbox_sessions TO service_role;

COMMIT;
