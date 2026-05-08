-- Per-conversation provider override. NULL = use the bot's resolved
-- routing (alias weights + task_routing_rules). When set, the slug is
-- passed as `preferProvider` to LLMRouter so the chat turn (and its
-- audit_log row) lands on the chosen provider; the existing fallback
-- chain still kicks in if that provider 5xxs mid-turn.
--
-- Soft validation only: no FK / CHECK against llm_providers.slug. A
-- stale value (provider got renamed or disabled in admin) silently
-- falls through to "no enabled alias for slug on provider X" and the
-- iOS client surfaces it as an error — preferable to wedging the
-- column with a constraint we'd then have to keep in sync.

ALTER TABLE pendingbot.conversations
  ADD COLUMN provider_override text;
