-- Drop all per-conversation setting overrides. Settings now live solely
-- at the bot level (bots.model_id / bots.model_provider / bots.config.*);
-- the per-conversation override UI was already removed, leaving these
-- columns dead. Resolution everywhere falls back to the bot's own value.
--
--   model_slug_override   (0058) — chat model pin       → bots.model_id
--   provider_override     (0038) — API route pin        → bots.model_provider
--   vision_model_override (0064) — vision model pin      → bots.config.visionModel
--   voice_model_override  (2026..) — realtime model pin  → bots.config.voiceModel
--   envelope_settings     (0041) — letter loop defaults  → bots.config.envelope
--
-- No indexes / RLS policies / triggers reference these columns, so a plain
-- DROP COLUMN is safe.

ALTER TABLE pendingbot.conversations
  DROP COLUMN IF EXISTS model_slug_override,
  DROP COLUMN IF EXISTS provider_override,
  DROP COLUMN IF EXISTS vision_model_override,
  DROP COLUMN IF EXISTS voice_model_override,
  DROP COLUMN IF EXISTS envelope_settings;
