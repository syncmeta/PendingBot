-- 20260511043021_worldrouter_pricing_mirror.sql
--
-- Declares how WorldRouter's prices should be derived when the admin
-- pulls upstream prices from the board. WorldRouter is a LiteLLM proxy
-- that runs at ~70% of OpenRouter list and doesn't expose a public
-- prices endpoint — so the board treats it as a "mirror" of OpenRouter:
-- pull OpenRouter's /v1/models, find the alias on OpenRouter that maps
-- to the same canonical llm_models row as the WorldRouter alias, and
-- scale by `factor`.
--
-- Schema convention (jsonb shape):
--   provider.config = {
--     ...existing keys...,
--     pricing_source?: 'openrouter'           // future: 'native', 'azure_models', ...
--                    | { kind: 'native' }
--                    | { kind: 'mirror', source_slug: text, factor: number }
--   }
--
-- A missing pricing_source means "no upstream fetch wired up — admin
-- enters prices by hand on the alias page". OpenRouter itself doesn't
-- need this row because the board has a hardcoded native fetcher for
-- the 'openrouter' provider slug (see apps/board/lib/upstream-prices.ts).

BEGIN;

UPDATE pendingbot.llm_providers
   SET config = COALESCE(config, '{}'::jsonb)
              || jsonb_build_object(
                   'pricing_source',
                   jsonb_build_object(
                     'kind',         'mirror',
                     'source_slug',  'openrouter',
                     'factor',       0.7
                   )
                 )
 WHERE slug = 'worldrouter';

COMMIT;
