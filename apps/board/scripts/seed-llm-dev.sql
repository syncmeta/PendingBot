-- Local-dev convenience seed — canonical LLM models + one OpenRouter
-- alias each.
--
-- Why not a migration:
--   - Pricing is empirical and may shift; rates were lifted from
--     openrouter.ai/api/v1/models 2026-05. If OpenRouter rebases their
--     list, this seed needs updating — better to keep that out of
--     git history's permanent migrations.
--   - Apply locally only; prod opts in via admin UI or by running
--     this script manually against the prod DB after eyeballing.
--
-- All inserts ON CONFLICT DO NOTHING so reruns are harmless and admin
-- UI edits are never overwritten by re-applying. To force a repricing
-- instead, write a separate UPDATE against the alias rows afterwards.

BEGIN;

-- ── canonical models ────────────────────────────────────────────
INSERT INTO pendingbot.llm_models (slug, family, display_name, context_window, max_output_tokens, capabilities, enabled, notes) VALUES
  ('claude-opus-4.7', 'claude-4', 'Claude Opus 4.7', 200000, 8192,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true}'::jsonb, true,
   'Anthropic flagship.'),
  ('claude-sonnet-4.6', 'claude-4', 'Claude Sonnet 4.6', 200000, 8192,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true}'::jsonb, true, NULL),
  ('claude-haiku-4.5', 'claude-4', 'Claude Haiku 4.5', 200000, 8192,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true}'::jsonb, true, NULL),
  ('gpt-5.4', 'gpt-5', 'GPT-5.4', 256000, 16384,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true,"json_mode":true}'::jsonb, true, NULL),
  ('gpt-5.5', 'gpt-5', 'GPT-5.5', 256000, 16384,
   '{"vision":true,"tool_use":true,"prompt_cache":true,"reasoning":true,"json_mode":true}'::jsonb, true, NULL),
  ('deepseek-v4-pro', 'deepseek-v4', 'DeepSeek V4 Pro', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('kimi-k2.6', 'kimi-k2', 'Kimi K2.6', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('minimax-m2.7', 'minimax-m2', 'MiniMax M2.7', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('glm-5.1', 'glm-5', 'GLM 5.1', NULL, NULL,
   '{"vision":true,"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('qwen3.6-plus', 'qwen3', 'Qwen 3.6 Plus', NULL, NULL,
   '{"tool_use":true,"prompt_cache":true}'::jsonb, true, NULL),
  ('gemma-4-31b-it', 'gemma-4', 'Gemma 4 31B IT', NULL, NULL,
   '{"tool_use":false}'::jsonb, true, 'Google open-weights.')
ON CONFLICT (slug) DO NOTHING;

-- ── aliases (OpenRouter) ─────────────────────────────────────────
DO $$
DECLARE
  or_id uuid := (SELECT id FROM pendingbot.llm_providers WHERE slug='openrouter');
  m_id  uuid;
  pair record;
BEGIN
  -- canonical_slug, provider_model_id, input, cache_read, output
  -- (USD per 1M tokens; NULL = provider doesn't price that tier).
  FOR pair IN SELECT * FROM (VALUES
    ('claude-opus-4.7',   'anthropic/claude-opus-4.7',   5.0::numeric,    0.5::numeric,      25.0::numeric),
    ('claude-sonnet-4.6', 'anthropic/claude-sonnet-4.6', 3.0::numeric,    0.3::numeric,      15.0::numeric),
    ('claude-haiku-4.5',  'anthropic/claude-haiku-4.5',  1.0::numeric,    0.1::numeric,      5.0::numeric),
    ('gpt-5.4',           'openai/gpt-5.4',              2.5::numeric,    0.25::numeric,     15.0::numeric),
    ('gpt-5.5',           'openai/gpt-5.5',              5.0::numeric,    0.5::numeric,      30.0::numeric),
    ('minimax-m2.7',      'minimax/minimax-m2.7',        0.3::numeric,    0.059::numeric,    1.2::numeric),
    ('kimi-k2.6',         'moonshotai/kimi-k2.6',        0.75::numeric,   0.15::numeric,     3.5::numeric),
    ('deepseek-v4-pro',   'deepseek/deepseek-v4-pro',    0.435::numeric,  0.003625::numeric, 0.87::numeric),
    ('qwen3.6-plus',      'qwen/qwen3.6-plus',           0.325::numeric,  NULL::numeric,     1.95::numeric),
    ('gemma-4-31b-it',    'google/gemma-4-31b-it',       0.13::numeric,   NULL::numeric,     0.38::numeric),
    ('glm-5.1',           'z-ai/glm-5.1',                1.05::numeric,   0.525::numeric,    3.5::numeric)
  ) AS t(slug, or_pmid, or_in, or_cacheR, or_out)
  LOOP
    SELECT id INTO m_id FROM pendingbot.llm_models WHERE slug = pair.slug;

    INSERT INTO pendingbot.llm_model_aliases
      (model_id, provider_id, provider_model_id, enabled, weight,
       input_price, cached_input_price, output_price, notes)
    VALUES
      (m_id, or_id, pair.or_pmid, true, 100,
       pair.or_in, pair.or_cacheR, pair.or_out, 'OR list price 2026-05.')
    ON CONFLICT (model_id, provider_id) DO NOTHING;
  END LOOP;
END$$;

COMMIT;

-- Visibility check
SELECT m.slug, p.slug AS provider, a.weight,
       a.input_price AS in_$M, a.output_price AS out_$M,
       a.cached_input_price AS cacheR_$M
FROM pendingbot.llm_model_aliases a
JOIN pendingbot.llm_models m ON m.id = a.model_id
JOIN pendingbot.llm_providers p ON p.id = a.provider_id
ORDER BY m.slug, p.slug;
