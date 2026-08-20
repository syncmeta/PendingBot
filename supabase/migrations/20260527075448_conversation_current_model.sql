BEGIN;

ALTER TABLE pendingbot.conversations
  ADD COLUMN IF NOT EXISTS current_model_slug text,
  ADD COLUMN IF NOT EXISTS current_model_provider text;

COMMENT ON COLUMN pendingbot.conversations.current_model_slug IS
  'Conversation main model slug. Set once from the bot model pool when the conversation first needs a bot turn, then changed only by explicit answer choice.';

COMMENT ON COLUMN pendingbot.conversations.current_model_provider IS
  'Provider route hint for current_model_slug. NULL follows default routing; openrouter/openai/anthropic/google-ai-studio pin the gateway path.';

UPDATE pendingbot.conversations c
SET
  current_model_slug = b.model_id,
  current_model_provider = b.model_provider
FROM pendingbot.bots b
WHERE c.bot_id = b.id
  AND c.current_model_slug IS NULL
  AND c.conversation_type IN ('user_bot', 'self')
  AND b.model_id IS NOT NULL;

COMMIT;
