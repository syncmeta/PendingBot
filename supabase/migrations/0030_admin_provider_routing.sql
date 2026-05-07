-- Provider routing infrastructure for the admin panel + multi-provider LLM
-- router. Three new tables decouple the canonical model concept ("the
-- thing the bot wants to talk to", e.g. claude-opus-4.5) from where it
-- actually runs ("through which gateway, with which provider-specific
-- slug, at what price"). This lets us:
--
--   1. Switch a bot from OpenRouter to WorldRouter (or back) without
--      touching the bot row, just by flipping alias weights.
--   2. Track the same model's price across gateways (WorldRouter ~30%
--      cheaper than OpenRouter is the whole reason this exists).
--   3. Audit per-provider token spend, not just per-model.
--
-- Schema:
--   llm_providers       — gateway/direct vendor (openrouter, worldrouter, …)
--   llm_models          — canonical model identity (claude-opus-4.5, …)
--   llm_model_aliases   — (model × provider) → provider's actual id + price
--
-- Existing pendingbot.model_pricing stays for now (M1 is purely additive,
-- zero behavior change). Once the LLMRouter ships in M2 it'll read from
-- llm_model_aliases and model_pricing can be dropped in a follow-up.
--
-- Existing bots.model_id (free-form text like 'anthropic/claude-opus-4.5')
-- also stays untouched here. M2 introduces the canonical-id resolution
-- step in the router; backfill happens then so this migration is safe to
-- apply without code changes.
--
-- Prices are stored as USD per 1,000,000 tokens. Industry convention
-- (OpenRouter / Anthropic / OpenAI all publish per-1M), avoids the
-- precision drift you get with per-token decimals. numeric(12,6) tops
-- out at $999,999.999999/M which is more than enough.

BEGIN;

-- ============================================================
-- llm_providers — gateway / direct vendor registry
-- ============================================================

CREATE TABLE pendingbot.llm_providers (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    slug text NOT NULL,
    display_name text NOT NULL,
    base_url text NOT NULL,
    auth_type text DEFAULT 'bearer' NOT NULL,
    -- Wrangler/env var name where the API key lives. The key itself is
    -- never stored in the DB — admins see the ref name only.
    secret_ref text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    -- Lower priority = preferred. Used by the router as a tiebreaker
    -- after per-alias weight; also drives "which provider does the UI
    -- show first" ordering.
    priority integer DEFAULT 100 NOT NULL,
    -- Per-provider knobs: {extra_headers: {...}, sdk_hint: 'openai-compatible',
    -- supports_streaming: true, ...}. Router reads this; admin UI edits it.
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT llm_providers_pkey PRIMARY KEY (id),
    CONSTRAINT llm_providers_slug_uniq UNIQUE (slug),
    CONSTRAINT llm_providers_auth_type_check
        CHECK (auth_type = ANY (ARRAY['bearer'::text, 'header-x-api-key'::text]))
);
ALTER TABLE pendingbot.llm_providers OWNER TO postgres;

CREATE INDEX idx_llm_providers_enabled_priority
    ON pendingbot.llm_providers(enabled, priority);

-- ============================================================
-- llm_models — canonical model identity
-- ============================================================

CREATE TABLE pendingbot.llm_models (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    -- Stable name the rest of the system uses. Bots / router / audit
    -- code all refer to a model by slug, never by provider-specific id.
    slug text NOT NULL,
    family text,
    display_name text NOT NULL,
    context_window integer,
    max_output_tokens integer,
    -- {vision, tool_use, prompt_cache, reasoning, json_mode, …}
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    -- Soft EOL: panel shows a banner when set; router still routes,
    -- but it's a signal to migrate bots off this model.
    deprecated_at timestamp with time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT llm_models_pkey PRIMARY KEY (id),
    CONSTRAINT llm_models_slug_uniq UNIQUE (slug)
);
ALTER TABLE pendingbot.llm_models OWNER TO postgres;

CREATE INDEX idx_llm_models_enabled ON pendingbot.llm_models(enabled);

-- ============================================================
-- llm_model_aliases — (model × provider) routing rows
-- ============================================================

CREATE TABLE pendingbot.llm_model_aliases (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    model_id uuid NOT NULL,
    provider_id uuid NOT NULL,
    -- The string this provider expects in completions API. e.g.:
    --   OpenRouter:        'anthropic/claude-opus-4.5'
    --   Anthropic direct:  'claude-opus-4-5-20251022'
    --   WorldRouter:       (its own slug, TBD)
    provider_model_id text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    -- Routing weight. 0 = standby (only picked when all positive-weight
    -- aliases for the model are unavailable). Positive integers compete
    -- proportionally; the router picks within enabled aliases by
    -- weighted random or weighted-priority depending on routing_mode.
    weight integer DEFAULT 100 NOT NULL,
    -- Prices: USD per 1,000,000 tokens.
    input_price numeric(12,6) NOT NULL,
    cached_input_price numeric(12,6),
    output_price numeric(12,6) NOT NULL,
    -- Anthropic-style cache_creation tokens are billed at 1.25× input;
    -- expose it as its own column so providers without this concept
    -- can leave it null (router falls back to input_price × 1).
    cache_write_price numeric(12,6),
    currency text DEFAULT 'USD' NOT NULL,
    -- Per-alias knobs: {supports_prompt_cache: true, max_concurrency: 10, …}
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT llm_model_aliases_pkey PRIMARY KEY (id),
    CONSTRAINT llm_model_aliases_model_provider_uniq UNIQUE (model_id, provider_id),
    CONSTRAINT llm_model_aliases_model_id_fkey
        FOREIGN KEY (model_id) REFERENCES pendingbot.llm_models(id) ON DELETE CASCADE,
    CONSTRAINT llm_model_aliases_provider_id_fkey
        FOREIGN KEY (provider_id) REFERENCES pendingbot.llm_providers(id) ON DELETE CASCADE,
    CONSTRAINT llm_model_aliases_weight_nonneg CHECK (weight >= 0)
);
ALTER TABLE pendingbot.llm_model_aliases OWNER TO postgres;

-- Hot path: "give me all enabled aliases for model X, sorted by weight".
CREATE INDEX idx_llm_aliases_model_enabled_weight
    ON pendingbot.llm_model_aliases(model_id, enabled, weight DESC);
CREATE INDEX idx_llm_aliases_provider
    ON pendingbot.llm_model_aliases(provider_id);

-- ============================================================
-- audit_log — link to providers / aliases + route trace
-- ============================================================
--
-- Existing columns stay as-is. New columns are nullable so historical
-- rows remain valid; M2 router populates them on every new request.

ALTER TABLE pendingbot.audit_log
    ADD COLUMN provider_id uuid REFERENCES pendingbot.llm_providers(id),
    ADD COLUMN model_alias_id uuid REFERENCES pendingbot.llm_model_aliases(id),
    -- Per-attempt trace: [{provider_slug, alias_id, attempt, status,
    -- error_class, latency_ms}]. Lets the panel show fallback chains
    -- and "WorldRouter 429 → OpenRouter 200" diagnoses.
    ADD COLUMN route_trace jsonb,
    ADD COLUMN status text,
    ADD COLUMN error_class text;

-- idx_audit_user_time(user_id, created_at DESC) and
-- idx_audit_model_time(model_id, created_at DESC) already exist from
-- 0001_init.sql; not redeclared here.
CREATE INDEX idx_audit_provider_time
    ON pendingbot.audit_log(provider_id, created_at DESC);
CREATE INDEX idx_audit_task_time
    ON pendingbot.audit_log(task_type, created_at DESC);
CREATE INDEX idx_audit_status_time
    ON pendingbot.audit_log(status, created_at DESC)
    WHERE status IS NOT NULL;

-- ============================================================
-- admin_audit — every admin write leaves a trail
-- ============================================================

CREATE TABLE pendingbot.admin_audit (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    actor_id uuid,
    -- e.g. 'provider.update', 'alias.create', 'alias.disable',
    -- 'user.set_admin', 'audit.unmask_pii'
    action text NOT NULL,
    target_kind text NOT NULL,
    -- target's primary key (uuid or composite stringified). Free-form
    -- because targets across different tables don't share a key type.
    target_id text,
    before jsonb,
    after jsonb,
    ip text,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_audit_pkey PRIMARY KEY (id),
    CONSTRAINT admin_audit_actor_id_fkey
        FOREIGN KEY (actor_id) REFERENCES pendingbot.users(id) ON DELETE SET NULL
);
ALTER TABLE pendingbot.admin_audit OWNER TO postgres;

CREATE INDEX idx_admin_audit_actor_time
    ON pendingbot.admin_audit(actor_id, created_at DESC);
CREATE INDEX idx_admin_audit_target
    ON pendingbot.admin_audit(target_kind, target_id);
CREATE INDEX idx_admin_audit_action_time
    ON pendingbot.admin_audit(action, created_at DESC);

-- ============================================================
-- Aggregation views for the admin panel
-- ============================================================
--
-- Plain views, not materialized. The panel queries these with WHERE
-- filters on (day/month, user, provider, model, task) so PG is mostly
-- doing index scans on audit_log. If volume grows past the point where
-- this groans, swap to materialized + scheduled REFRESH.
--
-- All time bucketing in UTC; the panel converts to local for display.

CREATE VIEW pendingbot.v_audit_daily AS
SELECT
    date_trunc('day', created_at) AS day,
    user_id,
    provider_id,
    model_id,
    model_alias_id,
    task_type,
    count(*) AS request_count,
    coalesce(sum(input_tokens), 0) AS input_tokens,
    coalesce(sum(output_tokens), 0) AS output_tokens,
    coalesce(sum(cache_read_tokens), 0) AS cache_read_tokens,
    coalesce(sum(cache_write_tokens), 0) AS cache_write_tokens,
    coalesce(sum(cost_usd), 0) AS cost_usd,
    avg(latency_ms)::int AS avg_latency_ms,
    count(*) FILTER (WHERE status = 'error') AS error_count,
    count(*) FILTER (WHERE jsonb_array_length(coalesce(route_trace, '[]'::jsonb)) > 1)
        AS fallback_count
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE VIEW pendingbot.v_audit_monthly AS
SELECT
    date_trunc('month', created_at) AS month,
    user_id,
    provider_id,
    model_id,
    task_type,
    count(*) AS request_count,
    coalesce(sum(input_tokens), 0) AS input_tokens,
    coalesce(sum(output_tokens), 0) AS output_tokens,
    coalesce(sum(cache_read_tokens), 0) AS cache_read_tokens,
    coalesce(sum(cache_write_tokens), 0) AS cache_write_tokens,
    coalesce(sum(cost_usd), 0) AS cost_usd,
    avg(latency_ms)::int AS avg_latency_ms,
    count(*) FILTER (WHERE status = 'error') AS error_count
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5;

ALTER VIEW pendingbot.v_audit_daily OWNER TO postgres;
ALTER VIEW pendingbot.v_audit_monthly OWNER TO postgres;

-- ============================================================
-- RLS — admin tables are service_role only
-- ============================================================
--
-- Same pattern as bot_sandbox_sessions (0027): ENABLE RLS, no policies,
-- service_role bypasses. The admin Next.js app talks to Supabase
-- server-side with service role; nothing client-facing reads these.

ALTER TABLE pendingbot.llm_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE pendingbot.llm_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE pendingbot.llm_model_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE pendingbot.admin_audit ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE pendingbot.llm_providers TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE pendingbot.llm_models TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE pendingbot.llm_model_aliases TO service_role;
GRANT SELECT, INSERT
    ON TABLE pendingbot.admin_audit TO service_role;
GRANT SELECT
    ON pendingbot.v_audit_daily TO service_role;
GRANT SELECT
    ON pendingbot.v_audit_monthly TO service_role;

-- ============================================================
-- Seed: OpenRouter provider (the one we already use)
-- ============================================================
--
-- WorldRouter intentionally not seeded here — base_url, auth header
-- shape, and secret_ref name need to be confirmed against its real
-- API before going in. Add it via the admin UI or a follow-up
-- migration once those are nailed down.

INSERT INTO pendingbot.llm_providers (
    slug, display_name, base_url, auth_type, secret_ref,
    enabled, priority, notes
)
VALUES (
    'openrouter',
    'OpenRouter',
    'https://openrouter.ai/api/v1',
    'bearer',
    'OPENROUTER_API_KEY',
    true,
    200,
    'Multi-provider gateway. Currently the only wired provider; will become fallback once WorldRouter is added.'
)
ON CONFLICT (slug) DO NOTHING;

COMMIT;
