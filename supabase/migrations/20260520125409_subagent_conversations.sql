-- Sub-conversations for the subagent feature: a bot in conversation A
-- spawns a child conversation B with another bot (typically one with a
-- native API — Anthropic/Gemini/OpenAI). The child runs a focused task
-- and its result becomes the parent bot's tool_result.
--
-- Schema model:
--   conversations.parent_message_id — the parent's message (a bot turn
--     emitting a tool call) that spawned this child. NULL for the
--     normal top-level convs.
--   conversations.spawner_bot_id — the parent bot that issued the
--     delegation. NULL for top-level convs. Distinct from bot_id (the
--     child's own bot — the specialist being delegated TO).
--   conversation_type 'subagent' — the picker / list views filter
--     these out of the top-level conversation list; they only show
--     up nested under their parent message bubble.

ALTER TABLE pendingbot.conversations
  ADD COLUMN IF NOT EXISTS parent_message_id uuid
    REFERENCES pendingbot.messages(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.conversations
  ADD COLUMN IF NOT EXISTS spawner_bot_id uuid
    REFERENCES pendingbot.bots(id) ON DELETE SET NULL;

-- Index for "fetch all sub-convs of message X" — the conv list view
-- needs this when expanding a tool-call bubble.
CREATE INDEX IF NOT EXISTS conversations_parent_message_id_idx
  ON pendingbot.conversations (parent_message_id)
  WHERE parent_message_id IS NOT NULL;

-- Extend the conversation_type allowlist to include 'subagent'. The
-- existing values stay; the new one is the only addition.
ALTER TABLE pendingbot.conversations
  DROP CONSTRAINT IF EXISTS conversations_conversation_type_check;
ALTER TABLE pendingbot.conversations
  ADD  CONSTRAINT conversations_conversation_type_check
       CHECK (conversation_type = ANY (ARRAY[
         'user_bot'::text,
         'user_user'::text,
         'group'::text,
         'self'::text,
         'subagent'::text
       ]));
