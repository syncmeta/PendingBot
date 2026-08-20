-- Per-conversation realtime voice-model pin. Mirrors vision_model_override
-- (0064): NULL = follow the bot's default voice model; a non-NULL value is
-- a realtime model slug that wins over bots.config.voiceModel for this one
-- conversation. The voice-call /session route reads it into the precedence
-- chain conv override -> bot default -> DEFAULT_VOICE_MODEL_SLUG.

ALTER TABLE pendingbot.conversations
  ADD COLUMN voice_model_override text;

COMMENT ON COLUMN pendingbot.conversations.voice_model_override IS
  'Per-conv realtime voice model pin. NULL = follow the bot default '
  '(bots.config.voiceModel). When set, a realtime model slug used by '
  'POST /v1/realtime/session.';
