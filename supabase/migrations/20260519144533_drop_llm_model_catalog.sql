-- Drop the DB-backed LLM model catalog. Routing is now pure passthrough
-- (see apps/edge/src/llm/providers.ts): a model slug goes to the upstream
-- verbatim and the provider is just a path segment on the AI Gateway.
-- Model metadata and pricing are pulled live from the upstream catalogs;
-- per-request cost comes from the AI Gateway logs. The only thing this
-- side still owns is the global markup, which lives in billing_config.

BEGIN;

-- v_audit_daily / v_audit_monthly select audit_log.provider_id (and
-- v_audit_daily also model_alias_id), so they must be dropped before the
-- columns and recreated without them.
DROP VIEW IF EXISTS pendingbot.v_audit_daily;
DROP VIEW IF EXISTS pendingbot.v_audit_monthly;

-- audit_log referenced two of the doomed tables. Drop the columns (their
-- FKs go with them) — provider is derivable from model_id / task_type,
-- and model_alias_id is always null in the passthrough model.
ALTER TABLE pendingbot.audit_log
  DROP COLUMN IF EXISTS provider_id,
  DROP COLUMN IF EXISTS model_alias_id;

-- Drop in FK-dependency order: aliases + task rules reference models /
-- providers, so they go first. model_pricing is independent (legacy).
DROP TABLE IF EXISTS pendingbot.task_routing_rules;
DROP TABLE IF EXISTS pendingbot.llm_model_aliases;
DROP TABLE IF EXISTS pendingbot.model_pricing;
DROP TABLE IF EXISTS pendingbot.llm_models;
DROP TABLE IF EXISTS pendingbot.llm_providers;

CREATE VIEW pendingbot.v_audit_daily
  WITH (security_invoker = on) AS
SELECT
    date_trunc('day', created_at) AS day,
    user_id,
    model_id,
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
        AS fallback_count,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4;

CREATE VIEW pendingbot.v_audit_monthly
  WITH (security_invoker = on) AS
SELECT
    date_trunc('month', created_at) AS month,
    user_id,
    model_id,
    task_type,
    count(*) AS request_count,
    coalesce(sum(input_tokens), 0) AS input_tokens,
    coalesce(sum(output_tokens), 0) AS output_tokens,
    coalesce(sum(cache_read_tokens), 0) AS cache_read_tokens,
    coalesce(sum(cache_write_tokens), 0) AS cache_write_tokens,
    coalesce(sum(cost_usd), 0) AS cost_usd,
    avg(latency_ms)::int AS avg_latency_ms,
    count(*) FILTER (WHERE status = 'error') AS error_count,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4;

COMMIT;
