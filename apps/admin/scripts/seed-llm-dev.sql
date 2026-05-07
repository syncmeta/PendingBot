-- Local-dev convenience seed — 8 canonical LLM models + 16 aliases
-- (each model paired across openrouter + worldrouter).
--
-- Why not a migration:
--   - Pricing is empirical and may shift; OR rates were lifted from
--     openrouter.ai/api/v1/models 2026-05, WR rates from the public
--     pricing table on the same date. If either side rebases their
--     list, this seed needs updating — better to keep that out of
--     git history's permanent migrations.
--   - Apply locally only; prod opts in via admin UI or by running
--     this script manually against the prod DB after eyeballing.
--
-- WorldRouter pricing nuance (this is why the seed isn't blanket
-- 0.7×):
--   - WR quotes in Credits per 1M tokens; conversion is 100 Credits
--     = $1 USD (verified: closed-source models all land at exactly
--     0.7× OR list under that conversion, which matches the
--     operator's "七折" claim).
--   - That ratio holds for closed-source: claude-{opus,sonnet,haiku},
--     gpt-5.4, MiniMax-M2.7. WR is genuinely 30% off OR for these.
--   - Open-weight / Chinese-vendor models are priced independently
--     by WR (their own wholesale + margin). For some of these WR is
--     **more expensive** than OR — the seed flips alias weights so
--     the router defaults to OR for those.
--
-- Concretely (input-price ratios WR/OR):
--   claude-opus-4.7   0.70  ← WR primary
--   claude-sonnet-4.6 0.70  ← WR primary
--   claude-haiku-4.5  0.70  ← WR primary
--   gpt-5.4           0.70  ← WR primary
--   minimax-m2.7      0.70  ← WR primary
--   kimi-k2.6         0.887 ← WR primary (mild discount)
--   glm-5.1           1.067 ← OR primary (WR 6.7% pricier)
--   deepseek-v4-pro   2.80  ← OR primary (WR 180% pricier!)
--
-- Apply locally:
--   docker exec -i supabase_db_pendingbot psql -U postgres -d postgres \
--     < apps/admin/scripts/seed-llm-dev.sql
--
-- All inserts ON CONFLICT DO NOTHING so reruns are harmless and
-- admin UI edits are never overwritten by re-applying. To force a
-- repricing instead, write a separate UPDATE statement against the
-- alias rows after running this.

BEGIN;

-- ── canonical models ────────────────────────────────────────────
INSERT INTO pendingbot.llm_models (slug, family, display_name, context_window, max_output_tokens, capabilities, enabled, notes) VALUES
  ('claude-opus-4.7', 'claude-4', 'Claude Opus 4.7', 200000, 8192,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true}'::jsonb, true,
   'Anthropic flagship. Bots using anthropic/claude-opus-latest can be migrated to this slug.'),
  ('claude-sonnet-4.6', 'claude-4', 'Claude Sonnet 4.6', 200000, 8192,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true}'::jsonb, true, NULL),
  ('claude-haiku-4.5', 'claude-4', 'Claude Haiku 4.5', 200000, 8192,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true}'::jsonb, true, NULL),
  ('gpt-5.4', 'gpt-5', 'GPT-5.4', 256000, 16384,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true,"json_mode":true}'::jsonb, true, NULL),
  ('deepseek-v4-pro', 'deepseek-v4', 'DeepSeek V4 Pro', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('kimi-k2.6', 'kimi-k2', 'Kimi K2.6', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('minimax-m2.7', 'minimax-m2', 'MiniMax M2.7', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('glm-5.1', 'glm-5', 'GLM 5.1', NULL, NULL,
   '{"vision":true,"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL)
ON CONFLICT (slug) DO NOTHING;

-- ── aliases ─────────────────────────────────────────────────────
DO $$
DECLARE
  or_id uuid := (SELECT id FROM pendingbot.llm_providers WHERE slug='openrouter');
  wr_id uuid := (SELECT id FROM pendingbot.llm_providers WHERE slug='worldrouter');
  m_id  uuid;
  pair record;
BEGIN
  -- Each row carries enough columns for both providers' aliases:
  --   canonical_slug,
  --   or_pmid, or_in, or_cacheR, or_out, or_cacheW, or_weight,
  --   wr_pmid, wr_in, wr_cacheR, wr_out, wr_cacheW, wr_weight,
  --   wr_note
  -- All prices in USD per 1M tokens. NULL = "this provider doesn't
  -- price this token type separately" (recordAudit degrades to input
  -- price for cache reads in that case).
  FOR pair IN SELECT * FROM (VALUES
    -- closed-source: WR exact 0.7× OR, WR primary
    ('claude-opus-4.7',   'anthropic/claude-opus-4.7',   5.0::numeric,    0.5::numeric,    25.0::numeric,   6.25::numeric,    0::int,
                          'claude-opus-4-7',             3.5::numeric,    0.35::numeric,   17.5::numeric,   4.375::numeric,   100::int,
                          'WR price = exact 0.7× OR (closed-source 30% discount).'),
    ('claude-sonnet-4.6', 'anthropic/claude-sonnet-4.6', 3.0::numeric,    0.3::numeric,    15.0::numeric,   3.75::numeric,    0::int,
                          'claude-sonnet-4-6',           2.1::numeric,    0.21::numeric,   10.5::numeric,   2.625::numeric,   100::int,
                          'WR price = exact 0.7× OR (closed-source 30% discount).'),
    ('claude-haiku-4.5',  'anthropic/claude-haiku-4.5',  1.0::numeric,    0.1::numeric,    5.0::numeric,    1.25::numeric,    0::int,
                          'claude-haiku-4-5',            0.7::numeric,    0.07::numeric,   3.5::numeric,    0.875::numeric,   100::int,
                          'WR price = exact 0.7× OR (closed-source 30% discount).'),
    ('gpt-5.4',           'openai/gpt-5.4',              2.5::numeric,    0.25::numeric,   15.0::numeric,   NULL::numeric,    0::int,
                          'gpt-5.4',                     1.75::numeric,   0.175::numeric,  10.5::numeric,   NULL::numeric,    100::int,
                          'WR price = exact 0.7× OR. Neither side prices cache_write — null on both.'),
    ('minimax-m2.7',      'minimax/minimax-m2.7',        0.3::numeric,    0.059::numeric,  1.2::numeric,    NULL::numeric,    0::int,
                          'MiniMax-M2.7',                0.21::numeric,   0.0413::numeric, 0.84::numeric,   0.2625::numeric,  100::int,
                          'WR price = exact 0.7× OR. WR additionally exposes cache_write tier (OR doesn''t).'),

    -- mild discount: WR primary
    ('kimi-k2.6',         'moonshotai/kimi-k2.6',        0.75::numeric,   0.15::numeric,   3.5::numeric,    NULL::numeric,    0::int,
                          'kimi-k2.6',                   0.665::numeric,  0.112::numeric,  2.80::numeric,   0.665::numeric,   100::int,
                          'WR is 0.887× OR (~11% discount). WR exposes cache_write where OR doesn''t.'),

    -- INVERTED: WR more expensive — OR primary, WR weight 0
    ('deepseek-v4-pro',   'deepseek/deepseek-v4-pro',    0.435::numeric,  0.003625::numeric, 0.87::numeric, NULL::numeric,    100::int,
                          'deepseek-v4-pro',             1.218::numeric,  0.1015::numeric, 2.436::numeric,  1.218::numeric,   0::int,
                          'WR is 2.80× OR — never primary. weight=0 so router only falls back here when OR is unavailable.'),
    ('glm-5.1',           'z-ai/glm-5.1',                1.05::numeric,   0.525::numeric,  3.5::numeric,    NULL::numeric,    100::int,
                          'glm-5.1',                     1.12::numeric,   0.182::numeric,  3.52::numeric,   0.98::numeric,    0::int,
                          'WR is 1.067× OR — slightly pricier. weight=0; OR primary.')
  ) AS t(slug,
         or_pmid, or_in, or_cacheR, or_out, or_cacheW, or_weight,
         wr_pmid, wr_in, wr_cacheR, wr_out, wr_cacheW, wr_weight,
         wr_note)
  LOOP
    SELECT id INTO m_id FROM pendingbot.llm_models WHERE slug = pair.slug;

    INSERT INTO pendingbot.llm_model_aliases
      (model_id, provider_id, provider_model_id, enabled, weight,
       input_price, cached_input_price, output_price, cache_write_price, notes)
    VALUES
      (m_id, or_id, pair.or_pmid, true, pair.or_weight,
       pair.or_in, pair.or_cacheR, pair.or_out, pair.or_cacheW,
       'OR list price 2026-05.'),
      (m_id, wr_id, pair.wr_pmid, true, pair.wr_weight,
       pair.wr_in, pair.wr_cacheR, pair.wr_out, pair.wr_cacheW,
       pair.wr_note)
    ON CONFLICT (model_id, provider_id) DO NOTHING;
  END LOOP;
END$$;

COMMIT;

-- Visibility check
SELECT m.slug, p.slug AS provider, a.weight,
       a.input_price AS in_$M, a.output_price AS out_$M,
       a.cached_input_price AS cacheR_$M, a.cache_write_price AS cacheW_$M
FROM pendingbot.llm_model_aliases a
JOIN pendingbot.llm_models m ON m.id = a.model_id
JOIN pendingbot.llm_providers p ON p.id = a.provider_id
ORDER BY m.slug, p.slug;
