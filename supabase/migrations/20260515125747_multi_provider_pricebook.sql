-- Make OpenRouter the source of truth for canonical model metadata
-- (context_length, capabilities, modalities) and wire WorldRouter's
-- public catalog as a real pricing source instead of the
-- mirror-with-0.7x fiction.
--
-- Three things happen here:
--
-- 1. llm_models gains openrouter_canonical_slug — the OpenRouter id
--    (e.g. "anthropic/claude-haiku-4.5") this canonical model maps to.
--    Drives the model-sync flow on the board: capabilities, modalities,
--    context_window, max_output_tokens all get refreshed from
--    OpenRouter's /api/v1/models response keyed on this slug. Nullable
--    so models we haven't matched yet stay editable by hand.
--
-- 2. WorldRouter provider config.pricing_source flips to
--    {"kind":"worldrouter_public"} — the board fetches the public
--    /models page (DOM-embedded data-model-* attributes), so admins
--    can pull real per-million-token prices the same way they pull
--    OpenRouter's. The previous mirror-style 0.7x guesswork is gone.
--    (The mirror strategy is still decodable for any future provider
--    that needs it; we just don't lie that WR is exactly 0.7x.)
--
-- 3. OpenRouter provider config.pricing_source is set explicitly to
--    {"kind":"openrouter"} so dispatch reads it from config like
--    every other provider, rather than relying on the hardcoded
--    slug=='openrouter' branch.

BEGIN;

ALTER TABLE pendingbot.llm_models
  ADD COLUMN IF NOT EXISTS openrouter_canonical_slug text;

COMMENT ON COLUMN pendingbot.llm_models.openrouter_canonical_slug IS
  'OpenRouter catalog id (e.g. "anthropic/claude-haiku-4.5") this model maps to. Drives the model-sync flow: capabilities, modalities, context_window, max_output_tokens overwrite from OpenRouter on each sync. Null = unmapped, fields stay admin-managed.';

CREATE INDEX IF NOT EXISTS llm_models_openrouter_canonical_slug_idx
  ON pendingbot.llm_models (openrouter_canonical_slug)
  WHERE openrouter_canonical_slug IS NOT NULL;

-- Set pricing_source on both providers. jsonb_set with create_if_missing=true
-- so existing config keys (extra_headers, usage_include, etc.) are preserved.

UPDATE pendingbot.llm_providers
SET config = jsonb_set(
  coalesce(config, '{}'::jsonb),
  '{pricing_source}',
  '{"kind":"openrouter"}'::jsonb,
  true
)
WHERE slug = 'openrouter';

UPDATE pendingbot.llm_providers
SET config = jsonb_set(
  coalesce(config, '{}'::jsonb),
  '{pricing_source}',
  '{"kind":"worldrouter_public"}'::jsonb,
  true
)
WHERE slug = 'worldrouter';

COMMIT;
