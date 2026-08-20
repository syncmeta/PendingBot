-- Route all LLM provider traffic through Cloudflare AI Gateway
-- ("pendingbot" gateway in account 4c30...0d9f).
--
-- Pre-gateway the worker hit each provider's public API directly; the
-- only "fallback" was withFallback() in apps/edge/src/llm/router.ts
-- swapping providers on transient errors. Going through gateway buys:
--   - shared cross-isolate cache (cf-aig-cache-ttl per request, off by default)
--   - dashboard observability (token/cost/latency/cache-hit)
--   - gateway-side retry policy (2 attempts, 100ms exponential — set on
--     the gateway itself, not per request)
--   - foundation for Dynamic Routing later (conditional + cost-based
--     rules will be added in the dashboard, decoupled from this SQL)
--
-- WorldRouter is registered in the gateway as a *custom provider* (slug
-- 'worldrouter', base_url https://inference-api.worldrouter.ai/v1).
-- OpenAI + OpenRouter are gateway-native — the gateway's URL endpoint
-- happens to use the same trailing slug as our DB row, so all three
-- rows take the same shape: `${gateway-root}/${slug}`.
--
-- The worker code in router.ts is unchanged — it still uses the
-- OpenAI SDK with base_url + secret_ref. The SDK does
-- `${base_url}/chat/completions` and the gateway transparently proxies
-- the request to the upstream provider. Auth stays as the provider's
-- own bearer key (no cf-aig-authorization required because gateway
-- 'authentication' is off — worker→gateway auth can be added later).

BEGIN;

UPDATE pendingbot.llm_providers
SET base_url = 'https://gateway.ai.cloudflare.com/v1/YOUR_CF_ACCOUNT_ID/YOUR_AI_GATEWAY_NAME/openai'
WHERE slug = 'openai';

UPDATE pendingbot.llm_providers
SET base_url = 'https://gateway.ai.cloudflare.com/v1/YOUR_CF_ACCOUNT_ID/YOUR_AI_GATEWAY_NAME/openrouter'
WHERE slug = 'openrouter';

UPDATE pendingbot.llm_providers
SET base_url = 'https://gateway.ai.cloudflare.com/v1/YOUR_CF_ACCOUNT_ID/YOUR_AI_GATEWAY_NAME/worldrouter'
WHERE slug = 'worldrouter';

COMMIT;
