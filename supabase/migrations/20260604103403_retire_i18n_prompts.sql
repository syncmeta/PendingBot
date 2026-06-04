-- 20260604103403_retire_i18n_prompts.sql
--
-- Retire pendingbot.i18n_prompts. Prompt overrides moved out of Postgres
-- into Langfuse Prompt Management (prompt named `<name>/<locale>`, label
-- "production"). The edge prompt-loader (apps/edge/src/llm/prompt-loader.ts)
-- now warms its isolate-local cache from Langfuse instead of this table, with
-- the bundled apps/edge/prompts/<locale>/<name>.md files as the offline
-- fallback. No edge code reads i18n_prompts anymore (see #247), so the table
-- is dead weight.
--
-- Pre-launch, single env: the table only ever held seed rows (or was empty),
-- so dropping it loses no user-authored content worth preserving — the
-- canonical prompt source is the bundled .md / Langfuse pair.

BEGIN;

DROP TABLE IF EXISTS pendingbot.i18n_prompts;

COMMIT;
