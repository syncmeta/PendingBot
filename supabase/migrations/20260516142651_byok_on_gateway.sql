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
-- Also disables the worldrouter provider — it was seeded (0032) but
-- never wired (WORLDROUTER_API_KEY was always unset) and is not part of
-- the post-cutover provider set (openai, openrouter). It is DISABLED,
-- not deleted: audit_log rows still reference its aliases via FK, and
-- dropping that billing history isn't worth it. Disabling keeps the
-- router (pickAlias) from ever selecting it.
--
-- DEPLOY ORDERING: this migration must land together with the worker
-- build that contains the BYOK buildClient() — applying it against an
-- older worker that still reads secret_ref would break LLM routing.

BEGIN;

-- Neutralise the worldrouter provider without breaking audit_log FKs:
-- disable its aliases, any routing rules that prefer it, and the row.
UPDATE pendingbot.llm_model_aliases
   SET enabled = false
 WHERE provider_id IN (
   SELECT id FROM pendingbot.llm_providers WHERE slug = 'worldrouter'
 );

UPDATE pendingbot.task_routing_rules
   SET enabled = false
 WHERE prefer_provider_id IN (
   SELECT id FROM pendingbot.llm_providers WHERE slug = 'worldrouter'
 );

UPDATE pendingbot.llm_providers
   SET enabled = false
 WHERE slug = 'worldrouter';

-- secret_ref + auth_type are no longer read by the router. Dropping
-- auth_type also drops its CHECK constraint (llm_providers_auth_type_check).
ALTER TABLE pendingbot.llm_providers DROP COLUMN secret_ref;
ALTER TABLE pendingbot.llm_providers DROP COLUMN auth_type;

COMMIT;
