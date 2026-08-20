-- Prune providers no longer wired by the worker.
--
-- The web-tool stack now runs entirely through MCP — bot-reply and
-- envelope-runner both go through apps/edge/src/mcp/client.ts to Exa's
-- hosted MCP. Brave, Serper, and Firecrawl are not referenced anywhere
-- in the worker code; their lib/web.ts wrappers were deleted alongside
-- this migration.
--
-- Tavily rows STAY: the skill mechanism (next milestone) will plumb
-- Tavily through a subscribable skill, so the price rows need to be
-- in place when that lands.
--
-- audit_web_tool_calls rows are NOT touched. Each historical row
-- already carries its own materialized cost_usd (snapshot at
-- meter-record time), not a join to web_tool_prices, so dropping a
-- price row never retroactively changes a bill.

BEGIN;

DELETE FROM pendingbot.web_tool_prices
WHERE (provider, kind) IN (
    ('brave',     'search'),
    ('serper',    'search'),
    ('firecrawl', 'scrape')
);

COMMIT;
