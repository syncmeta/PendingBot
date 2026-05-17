-- BYOK-on-gateway: provider auth moves into the AI Gateway dashboard.
--
-- Before: each llm_providers row named a worker env var (secret_ref) and
-- an auth_type; buildClient() in apps/edge/src/llm/router.ts indexed
-- env[secret_ref] for the upstream provider key and let the OpenAI SDK
-- send it as the Authorization header.
--
-- After: provider keys are stored in the AI Gateway dashboard (BYOK /
-- "Store Keys"). The worker authenticates to the gateway itself with the
-- cf-aig-authorization header (CF_AIG_RUN_TOKEN) and the gateway injects
-- the stored upstream key. secret_ref + auth_type are therefore obsolete.
--
-- Also drops the worldrouter provider — it was seeded (0032) but never
-- wired (WORLDROUTER_API_KEY was always unset) and is not part of the
-- post-cutover provider set (openai, openrouter).
--
-- DEPLOY ORDERING: this migration must land together with the worker
-- build that contains the BYOK buildClient() — applying it against an
-- older worker that still reads secret_ref would break LLM routing.

BEGIN;

-- Remove the worldrouter provider and everything that points at it.
-- Aliases first (FK), then any routing rules, then the row.
DELETE FROM pendingbot.llm_model_aliases
 WHERE provider_id IN (
   SELECT id FROM pendingbot.llm_providers WHERE slug = 'worldrouter'
 );

DELETE FROM pendingbot.task_routing_rules
 WHERE prefer_provider_id IN (
   SELECT id FROM pendingbot.llm_providers WHERE slug = 'worldrouter'
 );

DELETE FROM pendingbot.llm_providers WHERE slug = 'worldrouter';

-- secret_ref + auth_type are no longer read by the router. Dropping
-- auth_type also drops its CHECK constraint (llm_providers_auth_type_check).
ALTER TABLE pendingbot.llm_providers DROP COLUMN secret_ref;
ALTER TABLE pendingbot.llm_providers DROP COLUMN auth_type;

COMMIT;
