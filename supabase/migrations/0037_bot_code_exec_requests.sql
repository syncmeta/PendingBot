-- Pending code-exec approval requests. Bridges the bot's
-- request_execute_code tool call (which pauses inside the SSE turn) and
-- the iOS approval card it triggers.
--
-- Lifecycle:
--   1. Bot calls request_execute_code(code, reason, estimated_seconds).
--   2. Edge tool inserts a row {status='pending'}, emits a
--      `code_exec_request` SSE event with {id, code, reason,
--      estimated_seconds}, then short-polls this row every ~500ms (the
--      Worker is happy to keep the SSE response open during the wait;
--      it has no DOs and no other cross-request signal).
--   3. iOS shows a confirmation card with two buttons. User decision
--      arrives via POST /v1/code-exec-requests/:id/respond, which sets
--      status='approved' or 'denied' and stamps responded_at.
--   4. Tool sees the status flip, runs the code in the sandbox if
--      approved, and returns the outcome to the model. If 120s passes
--      with no decision, status='timeout' and the tool returns
--      {approved:false, timeout:true} so the bot can recover.
--
-- We keep the code text in the row so the iOS card can render a code
-- preview without trusting an in-memory event channel — if the user
-- backgrounds and re-opens the app, a future endpoint can still
-- reconstruct the pending card from the DB.
--
-- Service role only — no end-user client touches this table directly.
-- Reads/writes happen through edge Worker endpoints that authenticate
-- the user via JWT and check ownership explicitly.

BEGIN;

CREATE TABLE pendingbot.bot_code_exec_requests (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    bot_id uuid NOT NULL,
    code text NOT NULL,
    reason text NOT NULL,
    estimated_seconds integer NOT NULL,
    status text DEFAULT 'pending' NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    responded_at timestamp with time zone,
    CONSTRAINT bot_code_exec_requests_pkey PRIMARY KEY (id),
    CONSTRAINT bot_code_exec_requests_status_chk
      CHECK (status IN ('pending', 'approved', 'denied', 'timeout')),
    CONSTRAINT bot_code_exec_requests_estimated_chk
      CHECK (estimated_seconds >= 0 AND estimated_seconds <= 600),
    CONSTRAINT bot_code_exec_requests_conversation_id_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
    CONSTRAINT bot_code_exec_requests_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE,
    CONSTRAINT bot_code_exec_requests_bot_id_fkey
      FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE CASCADE
);
ALTER TABLE pendingbot.bot_code_exec_requests OWNER TO postgres;

-- Lookup by id is the hot path (the tool's poll); UUID PK already covers it.
-- A secondary index on (user_id, status) helps an eventual "list my pending
-- approvals" endpoint without scanning history.
CREATE INDEX idx_code_exec_requests_user_status
  ON pendingbot.bot_code_exec_requests(user_id, status);

ALTER TABLE pendingbot.bot_code_exec_requests ENABLE ROW LEVEL SECURITY;
-- No policies = no client access. service_role bypasses RLS.

GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.bot_code_exec_requests TO service_role;

COMMIT;
