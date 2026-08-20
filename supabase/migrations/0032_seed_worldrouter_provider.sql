-- Seed the WorldRouter provider row. Same pattern as the OpenRouter
-- seed in 0030: idempotent ON CONFLICT DO NOTHING so re-running the
-- migration (or applying it after admin already added the row via UI)
-- is harmless.
--
-- Empirical specs (probed 2026-05; LiteLLM proxy under the hood):
--   - base URL accepts /v1/chat/completions (OpenAI SDK can use the
--     /v1 form unchanged)
--   - bearer auth, error envelope shape matches LiteLLM
--   - flat model slugs (no vendor/ prefix): kimi-k2.6, MiniMax-M2.7,
--     qwen3.6-plus etc. — different from OpenRouter's vendor/name
--     style, so each canonical model needs its own (model, provider)
--     alias row with provider-specific provider_model_id.
--
-- The actual API key is set out of band via:
--   bunx wrangler secret put WORLDROUTER_API_KEY  (in apps/edge/)
-- and is referenced here only by name (secret_ref). Without the
-- secret bound, resolveRoute() throws NoRouteError when this provider
-- is selected — which is the right behaviour: never silently fall
-- back to OpenRouter for a request that explicitly asked for WR.
--
-- Priority 100 vs OpenRouter's 200 means WR is preferred at the
-- provider-priority tiebreaker level; per-alias weight still wins
-- first, so admin can pin individual models to either side.

BEGIN;

INSERT INTO pendingbot.llm_providers (
    slug, display_name, base_url, auth_type, secret_ref,
    enabled, priority, notes
)
VALUES (
    'worldrouter',
    'WorldRouter',
    'https://inference-api.worldrouter.ai/v1',
    'bearer',
    'WORLDROUTER_API_KEY',
    true,
    100,
    'LiteLLM proxy, ~30% off OpenRouter list. Flat slug naming (no vendor/ prefix): kimi-k2.6, MiniMax-M2.7, qwen3.6-plus, etc.'
)
ON CONFLICT (slug) DO NOTHING;

COMMIT;
