-- Per-conversation model override. When set, this conv's bot turns use this
-- model slug instead of `bots.model_id`. NULL means "follow the bot default".
--
-- Mirrors the existing `provider_override` pattern (0038) — column on
-- `conversations`, no separate table. The PATCH is gated in the Worker:
-- only the creator of a *private* bot can pin a model, and that gate
-- applies to the per-bot scope (which directly updates `bots.model_id`)
-- as well — both surfaces refuse on public/preset bots.

BEGIN;

ALTER TABLE pendingbot.conversations
    ADD COLUMN IF NOT EXISTS model_slug_override text;

COMMENT ON COLUMN pendingbot.conversations.model_slug_override IS
    'Per-conv model pin (OpenRouter slug). NULL = use bots.model_id. Settable only on convs whose bot is private and owned by the user.';

COMMIT;
