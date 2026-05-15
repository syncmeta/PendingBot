-- Swap billing source: locally-computed price-book cost is authoritative;
-- provider-reported cost moves to a separate column for audit/comparison.
--
-- Before this migration:
--   audit_log.cost_usd            = provider-reported (drives PND debit)
--   audit_log.estimated_cost_usd  = local price-book (audit-only)
--
-- After:
--   audit_log.cost_usd            = local price-book from llm_model_aliases
--                                   (drives PND debit). Falls back to the
--                                   provider-reported value only for
--                                   passthrough/unpriced aliases.
--   audit_log.provider_cost_usd   = provider-reported cost (audit-only;
--                                   null when the upstream does not return
--                                   cost, e.g. WorldRouter).
--
-- The flip lets us bill providers that don't return cost (WorldRouter) and
-- gives us an apples-to-apples local-vs-provider diff for the providers
-- that do (OpenRouter), so we can validate the local calculator before
-- extending it to new OpenAI-compatible upstreams.
--
-- Views v_audit_daily / v_audit_monthly are recreated because they
-- referenced estimated_cost_usd. The column is dropped after its values
-- migrate into the new cost_usd.

DROP VIEW IF EXISTS pendingbot.v_audit_daily;
DROP VIEW IF EXISTS pendingbot.v_audit_monthly;

ALTER TABLE pendingbot.audit_log
  ADD COLUMN IF NOT EXISTS provider_cost_usd numeric(12,6);

UPDATE pendingbot.audit_log
SET provider_cost_usd = cost_usd
WHERE provider_cost_usd IS NULL
  AND cost_usd IS NOT NULL;

UPDATE pendingbot.audit_log
SET cost_usd = estimated_cost_usd
WHERE estimated_cost_usd IS NOT NULL;

ALTER TABLE pendingbot.audit_log
  DROP COLUMN IF EXISTS estimated_cost_usd;

COMMENT ON COLUMN pendingbot.audit_log.cost_usd IS
  'Locally-computed LLM cost in USD from llm_model_aliases pricing. Drives PND debit. Falls back to provider_cost_usd when the alias has no price rows (passthrough). Null when neither is known.';
COMMENT ON COLUMN pendingbot.audit_log.provider_cost_usd IS
  'Provider-reported LLM cost in USD (when the upstream returns it). Audit-only — kept to validate the local calculator against OpenRouter and other gateways that report cost. Null for providers that do not return cost (e.g. WorldRouter).';

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
    coalesce(sum(provider_cost_usd), 0) AS provider_cost_usd,
    avg(latency_ms)::int AS avg_latency_ms,
    count(*) FILTER (WHERE status = 'error') AS error_count,
    count(*) FILTER (WHERE jsonb_array_length(coalesce(route_trace, '[]'::jsonb)) > 1)
        AS fallback_count,
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
    coalesce(sum(provider_cost_usd), 0) AS provider_cost_usd,
    avg(latency_ms)::int AS avg_latency_ms,
    count(*) FILTER (WHERE status = 'error') AS error_count,
    coalesce(sum(tool_cost_usd), 0) AS tool_cost_usd
FROM pendingbot.audit_log
GROUP BY 1, 2, 3, 4, 5;
