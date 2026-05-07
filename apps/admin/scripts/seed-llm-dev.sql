-- Local-dev convenience seed — 8 canonical LLM models + 16 aliases
-- (each model paired across openrouter + worldrouter).
--
-- Why not a migration:
--   - OR prices are exact (lifted from openrouter.ai/api/v1/models on
--     2026-05; per-1M units after × 1e6 conversion).
--   - WR prices are 0.7× OR estimates because WR doesn't expose a
--     pricing API and the user described it loosely as "七折". These
--     need to be verified against the WR dashboard and corrected per
--     model in admin /aliases. Pushing 0.7× into a migration would
--     bake that estimate into prod — instead, prod admin enters real
--     prices through the UI.
--
-- Apply locally:
--   docker exec -i supabase_db_pendingbot psql -U postgres -d postgres \
--     < apps/admin/scripts/seed-llm-dev.sql
--
-- Convention: weight 100 = primary (WR), weight 0 = fallback (OR).
-- All inserts ON CONFLICT DO NOTHING so reruns are harmless and
-- admin UI edits are never overwritten by re-applying.

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
-- Helper: pull provider IDs once.
DO $$
DECLARE
  or_id uuid := (SELECT id FROM pendingbot.llm_providers WHERE slug='openrouter');
  wr_id uuid := (SELECT id FROM pendingbot.llm_providers WHERE slug='worldrouter');
  m_id  uuid;
  pair record;
BEGIN
  -- Each row: canonical_slug, or_pmid, or_in, or_cacheR, or_out, or_cacheW, wr_pmid, wr_in, wr_cacheR, wr_out, wr_cacheW
  FOR pair IN SELECT * FROM (VALUES
    ('claude-opus-4.7',   'anthropic/claude-opus-4.7',   5.0::numeric,    0.5::numeric,    25.0::numeric,   6.25::numeric,
                          'claude-opus-4-7',             3.5::numeric,    0.35::numeric,   17.5::numeric,   4.375::numeric),
    ('claude-sonnet-4.6', 'anthropic/claude-sonnet-4.6', 3.0::numeric,    0.3::numeric,    15.0::numeric,   3.75::numeric,
                          'claude-sonnet-4-6',           2.1::numeric,    0.21::numeric,   10.5::numeric,   2.625::numeric),
    ('claude-haiku-4.5',  'anthropic/claude-haiku-4.5',  1.0::numeric,    0.1::numeric,    5.0::numeric,    1.25::numeric,
                          'claude-haiku-4-5',            0.7::numeric,    0.07::numeric,   3.5::numeric,    0.875::numeric),
    ('gpt-5.4',           'openai/gpt-5.4',              2.5::numeric,    0.25::numeric,   15.0::numeric,   NULL::numeric,
                          'gpt-5.4',                     1.75::numeric,   0.175::numeric,  10.5::numeric,   NULL::numeric),
    ('deepseek-v4-pro',   'deepseek/deepseek-v4-pro',    0.435::numeric,  0.003625::numeric, 0.87::numeric, NULL::numeric,
                          'deepseek-v4-pro',             0.3045::numeric, 0.002538::numeric, 0.609::numeric, NULL::numeric),
    ('kimi-k2.6',         'moonshotai/kimi-k2.6',        0.75::numeric,   0.15::numeric,   3.5::numeric,    NULL::numeric,
                          'kimi-k2.6',                   0.525::numeric,  0.105::numeric,  2.45::numeric,   NULL::numeric),
    ('minimax-m2.7',      'minimax/minimax-m2.7',        0.3::numeric,    0.059::numeric,  1.2::numeric,    NULL::numeric,
                          'MiniMax-M2.7',                0.21::numeric,   0.0413::numeric, 0.84::numeric,   NULL::numeric),
    ('glm-5.1',           'z-ai/glm-5.1',                1.05::numeric,   0.525::numeric,  3.5::numeric,    NULL::numeric,
                          'glm-5.1',                     0.735::numeric,  0.3675::numeric, 2.45::numeric,   NULL::numeric)
  ) AS t(slug, or_pmid, or_in, or_cacheR, or_out, or_cacheW, wr_pmid, wr_in, wr_cacheR, wr_out, wr_cacheW)
  LOOP
    SELECT id INTO m_id FROM pendingbot.llm_models WHERE slug = pair.slug;

    INSERT INTO pendingbot.llm_model_aliases
      (model_id, provider_id, provider_model_id, enabled, weight,
       input_price, cached_input_price, output_price, cache_write_price, notes)
    VALUES
      (m_id, or_id, pair.or_pmid, true, 0,
       pair.or_in, pair.or_cacheR, pair.or_out, pair.or_cacheW,
       'OR list price 2026-05. weight=0 = fallback only.'),
      (m_id, wr_id, pair.wr_pmid, true, 100,
       pair.wr_in, pair.wr_cacheR, pair.wr_out, pair.wr_cacheW,
       'WR price = 0.7× OR (ESTIMATE, verify in WR dashboard).')
    ON CONFLICT (model_id, provider_id) DO NOTHING;
  END LOOP;
END$$;

COMMIT;

-- Visibility check
SELECT m.slug, p.slug AS provider, a.provider_model_id, a.weight, a.input_price, a.output_price
FROM pendingbot.llm_model_aliases a
JOIN pendingbot.llm_models m ON m.id = a.model_id
JOIN pendingbot.llm_providers p ON p.id = a.provider_id
ORDER BY m.slug, p.slug;
