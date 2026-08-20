-- 20260511034611_web_tool_billing.sql
--
-- Adds billing + audit coverage for external search / crawl services that
-- the bot calls during a chat reply (search_web / read_url) or while
-- writing a letter (web_search / fetch_url in the scroll runner).
--
-- Until now the LLM call itself was the only thing in audit_log: each row
-- captured token usage + cost_usd + cost_credits and was billed via
-- billing_debit. The HTTP calls to Brave / Tavily / Exa / Serper /
-- Firecrawl that the LLM fired underneath were invisible to the audit
-- log and free to the user.
--
-- Long-term shape:
--   1. Pricing lives in DB (`web_tool_prices`). Adding a new provider or
--      retuning a price is a one-row DML, not a worker deploy.
--   2. Each LLM turn rolls up its web-tool spend into the *parent*
--      audit_log row via a new `tool_cost_usd` column. cost_credits
--      becomes the combined debit (LLM + tools) so billing_debit stays a
--      single-call code path — no second ledger.
--   3. Per-call detail lands in `audit_web_tool_calls` keyed by
--      audit_log_id. The breakdown is for ops/UI; the parent row is the
--      source of truth for what got debited.
--
-- recordAudit (apps/edge/src/llm/router.ts) owns the writes to both
-- tables. The worker-side WebToolMeter (apps/edge/src/lib/web-meter.ts)
-- is the single chokepoint that records each HTTP call — making it
-- impossible for a caller to invoke a web tool without metering.

BEGIN;

-- ── 1. Per-call cost rollup on the parent audit row ─────────────────────
-- `cost_usd` stays LLM-only so existing dashboards keep meaning. Tool
-- cost goes in its own column and the worker writes the combined value
-- into cost_credits for the debit. NULL = "no web tools called on this
-- turn", distinct from 0 (called but errored / unpriced).

ALTER TABLE pendingbot.audit_log
    ADD COLUMN tool_cost_usd numeric(12,6);

COMMENT ON COLUMN pendingbot.audit_log.tool_cost_usd IS
    'Sum of audit_web_tool_calls.cost_usd for this row. NULL when no '
    'web tools were called. cost_credits already includes the markup '
    'on (cost_usd + tool_cost_usd).';

-- ── 2. Pricing table — single source of truth for unit costs ────────────
-- (provider, kind) primary key so the same provider can offer both
-- search and scrape with distinct prices (Tavily, Exa). unit_cost_usd is
-- the wholesale cost per call; the worker applies the same markup as
-- LLM cost via usdToPnd before debiting.

CREATE TABLE pendingbot.web_tool_prices (
    provider        text NOT NULL,
    kind            text NOT NULL,
    unit_cost_usd   numeric(12,6) NOT NULL,
    notes           text,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT web_tool_prices_pkey PRIMARY KEY (provider, kind),
    CONSTRAINT web_tool_prices_kind_chk CHECK (kind IN ('search','scrape')),
    CONSTRAINT web_tool_prices_cost_chk CHECK (unit_cost_usd >= 0)
);
ALTER TABLE pendingbot.web_tool_prices OWNER TO postgres;

COMMENT ON TABLE pendingbot.web_tool_prices IS
    'Per-call wholesale price (USD) for external search / scrape '
    'providers. Edited by ops without a worker deploy; worker reads on '
    'each LLM turn (cached for the duration of the request).';

INSERT INTO pendingbot.web_tool_prices (provider, kind, unit_cost_usd, notes) VALUES
    ('brave',     'search', 0.005000, '$5 / 1k queries — Brave Search API Pro tier'),
    ('tavily',    'search', 0.008000, 'basic search; advanced depth is ~0.016'),
    ('exa',       'search', 0.005000, 'neural/keyword/auto search'),
    ('serper',    'search', 0.000300, '$0.30 / 1k queries — Serper starter'),
    ('firecrawl', 'scrape', 0.001500, 'hobby tier, ~$0.0015 per page'),
    ('tavily',    'scrape', 0.005000, '/extract endpoint, per URL (basic)'),
    ('exa',       'scrape', 0.001000, '/contents endpoint, per id');

ALTER TABLE pendingbot.web_tool_prices ENABLE ROW LEVEL SECURITY;
-- No public/authenticated GRANTs — ops uses Studio (service_role) for
-- reads and writes. Workers read via service-role.

-- ── 3. Per-call audit ──────────────────────────────────────────────────
-- Mirrors how audit_log_splits hangs off audit_log: FK with ON DELETE
-- CASCADE so cleaning up an audit row sweeps its tool breakdown.

CREATE TABLE pendingbot.audit_web_tool_calls (
    id              uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    audit_log_id    uuid NOT NULL,
    provider        text NOT NULL,
    kind            text NOT NULL,
    -- query string (search) or URL (scrape). Truncated by the worker to
    -- 500 chars before insert so a giant URL or a giant query doesn't
    -- bloat the table.
    target          text NOT NULL,
    status          text NOT NULL,
    error_class     text,
    latency_ms      integer,
    -- Only populated for kind='search'; NULL for scrapes.
    result_count    integer,
    -- Wholesale USD cost from web_tool_prices at the time of the call.
    -- 0 on error (we don't charge for failures, matching the LLM
    -- behavior in recordAudit).
    cost_usd        numeric(12,6) NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT audit_web_tool_calls_pkey PRIMARY KEY (id),
    CONSTRAINT audit_web_tool_calls_audit_fkey
        FOREIGN KEY (audit_log_id) REFERENCES pendingbot.audit_log(id)
        ON DELETE CASCADE,
    CONSTRAINT audit_web_tool_calls_kind_chk CHECK (kind IN ('search','scrape')),
    CONSTRAINT audit_web_tool_calls_status_chk CHECK (status IN ('success','error')),
    CONSTRAINT audit_web_tool_calls_cost_chk CHECK (cost_usd >= 0)
);
ALTER TABLE pendingbot.audit_web_tool_calls OWNER TO postgres;

COMMENT ON TABLE pendingbot.audit_web_tool_calls IS
    'Per-call detail for external web search / scrape invocations made '
    'during a single LLM turn. Joined to audit_log via audit_log_id; '
    'sum(cost_usd) on this table = audit_log.tool_cost_usd for the '
    'parent row.';

CREATE INDEX idx_audit_web_tool_calls_audit
    ON pendingbot.audit_web_tool_calls(audit_log_id);

CREATE INDEX idx_audit_web_tool_calls_provider_time
    ON pendingbot.audit_web_tool_calls(provider, kind, created_at DESC);

ALTER TABLE pendingbot.audit_web_tool_calls ENABLE ROW LEVEL SECURITY;

-- Owner of the parent audit row can read their own tool breakdown. Ops
-- via service_role bypasses RLS as elsewhere.
CREATE POLICY audit_web_tool_calls_self_read
    ON pendingbot.audit_web_tool_calls
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM pendingbot.audit_log al
            WHERE al.id = audit_web_tool_calls.audit_log_id
              AND al.user_id = auth.uid()
        )
    );

GRANT SELECT ON TABLE pendingbot.audit_web_tool_calls TO authenticated;
GRANT SELECT, INSERT, DELETE, UPDATE ON TABLE pendingbot.audit_web_tool_calls TO service_role;

COMMIT;
