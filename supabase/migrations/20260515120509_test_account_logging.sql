-- Test-account flag + verbose per-request log table.
--
-- Flipping `users.is_test_account = true` opts an account into detailed
-- request/response capture in `test_account_log`. The edge worker
-- skips writes for non-test users so production users incur no cost.

BEGIN;

ALTER TABLE pendingbot.users
    ADD COLUMN is_test_account boolean DEFAULT false NOT NULL;

COMMENT ON COLUMN pendingbot.users.is_test_account IS
    'When true, the edge worker captures verbose per-request logs into pendingbot.test_account_log. Off by default; flipped from the board for QA/debug accounts.';

CREATE TABLE pendingbot.test_account_log (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    kind text NOT NULL,
    route text,
    method text,
    status integer,
    latency_ms integer,
    request_id text,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    note text,
    CONSTRAINT test_account_log_pkey PRIMARY KEY (id),
    CONSTRAINT test_account_log_user_fkey
        FOREIGN KEY (user_id) REFERENCES pendingbot.users(id)
        ON DELETE CASCADE,
    CONSTRAINT test_account_log_latency_nonneg CHECK (latency_ms IS NULL OR latency_ms >= 0)
);

ALTER TABLE pendingbot.test_account_log OWNER TO postgres;

COMMENT ON TABLE pendingbot.test_account_log IS
    'Verbose per-request log for users marked is_test_account. Captures route, status, latency, and a free-form jsonb payload (headers/body slice, error context, etc.). Cascades on user delete.';
COMMENT ON COLUMN pendingbot.test_account_log.kind IS
    'Coarse category: http_request, llm_call, push, error, custom.';
COMMENT ON COLUMN pendingbot.test_account_log.payload IS
    'Free-form JSON. Edge code decides what to include; avoid raw secrets/tokens.';

CREATE INDEX idx_test_account_log_user_time
    ON pendingbot.test_account_log(user_id, occurred_at DESC);
CREATE INDEX idx_test_account_log_kind_time
    ON pendingbot.test_account_log(kind, occurred_at DESC);

ALTER TABLE pendingbot.test_account_log ENABLE ROW LEVEL SECURITY;

-- Service-role only. Board reads with service role; the worker writes
-- with the service-role supabase client. End-user clients have no
-- legitimate need to read or write this table.
GRANT SELECT, INSERT, DELETE, UPDATE ON TABLE pendingbot.test_account_log TO service_role;

COMMIT;
