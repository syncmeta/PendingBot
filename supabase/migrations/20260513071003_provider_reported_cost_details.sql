-- Record provider-reported request cost/details separately from our
-- local price-book estimate. From this migration onward:
--   audit_log.cost_usd           = provider-reported LLM cost, when present
--   audit_log.estimated_cost_usd = local price-book estimate for audit
-- User PND debit is computed from provider-reported cost_usd + tool_cost_usd.

ALTER TABLE pendingbot.audit_log
  ADD COLUMN IF NOT EXISTS estimated_cost_usd numeric(12,6),
  ADD COLUMN IF NOT EXISTS reported_provider text,
  ADD COLUMN IF NOT EXISTS cost_details jsonb,
  ADD COLUMN IF NOT EXISTS prompt_tokens_details jsonb,
  ADD COLUMN IF NOT EXISTS completion_tokens_details jsonb;

COMMENT ON COLUMN pendingbot.audit_log.cost_usd IS
  'Provider-reported LLM cost in USD for this request, when the provider returns it. Historical rows before 20260513071003 may contain the local estimate.';
COMMENT ON COLUMN pendingbot.audit_log.estimated_cost_usd IS
  'Local price-book LLM cost estimate in USD. Used for operator audit/comparison only, not for PND debit after 20260513071003.';
COMMENT ON COLUMN pendingbot.audit_log.reported_provider IS
  'Provider name returned by the upstream response, when available (for example an OpenRouter routed provider).';
COMMENT ON COLUMN pendingbot.audit_log.cost_details IS
  'Raw provider usage.cost_details JSON, when returned. Field names vary by provider.';
COMMENT ON COLUMN pendingbot.audit_log.prompt_tokens_details IS
  'Raw provider usage.prompt_tokens_details JSON, when returned. Field names vary by provider.';
COMMENT ON COLUMN pendingbot.audit_log.completion_tokens_details IS
  'Raw provider usage.completion_tokens_details JSON, when returned. Field names vary by provider.';

UPDATE pendingbot.audit_log
SET estimated_cost_usd = cost_usd
WHERE estimated_cost_usd IS NULL
  AND cost_usd IS NOT NULL;

CREATE OR REPLACE VIEW pendingbot.v_audit_daily AS
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
    coalesce(sum(estimated_cost_usd), 0) AS estimated_cost_usd,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE OR REPLACE VIEW pendingbot.v_audit_monthly AS
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
    coalesce(sum(estimated_cost_usd), 0) AS estimated_cost_usd,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5;
