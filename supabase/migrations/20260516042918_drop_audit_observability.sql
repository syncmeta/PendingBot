-- Drop the LLM observability surface that Cloudflare AI Gateway now owns.
--
-- Since all provider traffic flows through the gateway (migration
-- 20260515164621), the gateway's own logs carry per-request token
-- counts, cost, latency, status and the raw request/response payloads —
-- sliceable by task / user / conversation via the cf-aig-metadata header
-- the worker now attaches. That makes the worker's parallel capture
-- redundant:
--
--   * audit_model_calls — raw request/response payloads, one row per
--     provider call. Fully superseded by the gateway's payload logs.
--
--   * audit_log observability columns — local heuristic token estimates
--     and the provider-reported cost/details kept side-by-side with the
--     (now removed) locally-computed cost for reconciliation. Billing no
--     longer computes cost locally; it bills on the provider-reported
--     figure directly, so the reconciliation columns have no consumer.
--
-- What stays on audit_log: the billing-load-bearing columns (user_id,
-- conversation_id, cost_usd, tool_cost_usd, cost_credits, billing_status,
-- the token counts) plus task_type / model_id / provider_id /
-- model_alias_id / route_trace / status / error_class / latency_ms,
-- which are cheap and either billing- or routing-relevant.
--
-- audit_web_tool_calls is untouched — web search/scrape goes direct
-- (MCP), never through the gateway, so the gateway never sees it.

BEGIN;

DROP TABLE IF EXISTS pendingbot.audit_model_calls;

-- v_audit_daily / v_audit_monthly reference provider_cost_usd, so they
-- must be dropped before the column and recreated without it. They stay
-- as billing-relevant aggregations of audit_log (cost_usd, tokens,
-- counts) — just no longer carry the provider-reported reconciliation
-- sum.
DROP VIEW IF EXISTS pendingbot.v_audit_daily;
DROP VIEW IF EXISTS pendingbot.v_audit_monthly;

ALTER TABLE pendingbot.audit_log
  DROP COLUMN IF EXISTS est_input_tokens,
  DROP COLUMN IF EXISTS est_output_tokens,
  DROP COLUMN IF EXISTS provider_cost_usd,
  DROP COLUMN IF EXISTS reported_provider,
  DROP COLUMN IF EXISTS cost_details,
  DROP COLUMN IF EXISTS prompt_tokens_details,
  DROP COLUMN IF EXISTS completion_tokens_details;

CREATE VIEW pendingbot.v_audit_daily
  WITH (security_invoker = on) AS
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
        AS fallback_count,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE VIEW pendingbot.v_audit_monthly
  WITH (security_invoker = on) AS
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
    count(*) FILTER (WHERE status = 'error') AS error_count,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5;

COMMIT;
