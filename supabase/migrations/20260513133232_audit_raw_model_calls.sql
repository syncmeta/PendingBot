-- Store every raw model request/response emitted by the edge worker.
--
-- audit_log remains the per-business-turn rollup used for usage,
-- billing, and dashboards. A single rollup can cover multiple provider
-- requests (tool loops, scroll collaborator/write phases), so raw
-- payloads live in this child table ordered by seq.

BEGIN;

CREATE TABLE pendingbot.audit_model_calls (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    audit_log_id uuid NOT NULL,
    seq integer NOT NULL,
    task_type text NOT NULL,
    provider_id uuid,
    provider_slug text NOT NULL,
    model_alias_id uuid,
    model_id text NOT NULL,
    status text NOT NULL,
    error_class text,
    error_message text,
    latency_ms integer NOT NULL,
    raw_request jsonb NOT NULL,
    raw_response jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_model_calls_pkey PRIMARY KEY (id),
    CONSTRAINT audit_model_calls_audit_fkey
        FOREIGN KEY (audit_log_id) REFERENCES pendingbot.audit_log(id)
        ON DELETE CASCADE,
    CONSTRAINT audit_model_calls_provider_fkey
        FOREIGN KEY (provider_id) REFERENCES pendingbot.llm_providers(id)
        ON DELETE SET NULL,
    CONSTRAINT audit_model_calls_alias_fkey
        FOREIGN KEY (model_alias_id) REFERENCES pendingbot.llm_model_aliases(id)
        ON DELETE SET NULL,
    CONSTRAINT audit_model_calls_seq_positive CHECK (seq > 0),
    CONSTRAINT audit_model_calls_status_chk CHECK (status IN ('success','error')),
    CONSTRAINT audit_model_calls_latency_nonneg CHECK (latency_ms >= 0),
    CONSTRAINT audit_model_calls_audit_seq_uniq UNIQUE (audit_log_id, seq)
);

ALTER TABLE pendingbot.audit_model_calls OWNER TO postgres;

COMMENT ON TABLE pendingbot.audit_model_calls IS
    'Raw model API request/response payloads captured by the edge worker, one row per provider call and linked to audit_log.';
COMMENT ON COLUMN pendingbot.audit_model_calls.raw_request IS
    'JSON payload sent to the model provider SDK/API. Provider secrets and HTTP auth headers are not included.';
COMMENT ON COLUMN pendingbot.audit_model_calls.raw_response IS
    'Raw provider response JSON, or serialized provider error for failed calls.';

CREATE INDEX idx_audit_model_calls_audit
    ON pendingbot.audit_model_calls(audit_log_id, seq);
CREATE INDEX idx_audit_model_calls_provider_time
    ON pendingbot.audit_model_calls(provider_id, created_at DESC);
CREATE INDEX idx_audit_model_calls_task_time
    ON pendingbot.audit_model_calls(task_type, created_at DESC);

ALTER TABLE pendingbot.audit_model_calls ENABLE ROW LEVEL SECURITY;

-- Raw payloads can contain private prompts, message history, tool
-- arguments, and image data URLs. Keep access service-role only for now;
-- the admin board uses service-role, while end-user clients should not
-- read this table directly.
GRANT SELECT, INSERT, DELETE, UPDATE ON TABLE pendingbot.audit_model_calls TO service_role;

COMMIT;
