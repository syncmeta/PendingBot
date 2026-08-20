-- Per-bot API route pin.
--
-- A bot's model can be reached two ways: through the OpenRouter
-- passthrough (the default) or, for OpenAI models, straight to OpenAI's
-- native Responses API via the AI Gateway. The model picker offers both
-- as separate entries; the chosen route is stored here.
--
-- NULL  → default routing (OpenRouter passthrough).
-- 'openai' (an llm_providers.slug) → route directly to that provider's
--          native endpoint, bypassing the alias/weight machinery.
--
-- This is the bot-level default; conversations.provider_override is the
-- per-conversation counterpart and takes precedence when set.

alter table pendingbot.bots
  add column if not exists model_provider text;
