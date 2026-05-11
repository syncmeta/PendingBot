-- Add a conversation-scoped authorship branch to skills so chat-memo (and
-- any future per-conv bot artifact) has a home. Existing branches:
--   (bot_id+user_id, owner_id null)   — bot-private artifact for one user
--                                        (e.g. refreshBotNote)
--   (owner_id, bot_id+user_id null)   — user-owned skill
--   (all null, public)                — global public skill
-- New branch:
--   (bot_id+conversation_id, user_id null, owner_id null)
--     — bot-private artifact tied to one conversation. In 1v1 user_bot
--       convs this is equivalent to (bot_id, user_id) because user_bot is
--       (user, bot) one-to-one (see bootstrap in 0001); in group / self
--       convs it gives the bot a per-conv slot that doesn't depend on
--       picking a single "other user".
--
-- RLS untouched: existing skills_read already hides bot_id IS NOT NULL rows
-- from authenticated users; service_role bypasses RLS, which is the only
-- path that writes chat-memo (refreshChatMemo runs server-side).

BEGIN;

ALTER TABLE pendingbot.skills
  ADD COLUMN conversation_id uuid
    REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.skills
  DROP CONSTRAINT skills_authorship;

ALTER TABLE pendingbot.skills
  ADD CONSTRAINT skills_authorship CHECK (
    -- bot-private for one user (existing — bot-note)
    (bot_id IS NOT NULL AND user_id IS NOT NULL
     AND conversation_id IS NULL AND owner_id IS NULL)
    OR
    -- bot-private for one conversation (new — chat-memo)
    (bot_id IS NOT NULL AND conversation_id IS NOT NULL
     AND user_id IS NULL AND owner_id IS NULL)
    OR
    -- user-owned
    (owner_id IS NOT NULL
     AND bot_id IS NULL AND user_id IS NULL AND conversation_id IS NULL)
    OR
    -- public seed
    (owner_id IS NULL AND bot_id IS NULL AND user_id IS NULL
     AND conversation_id IS NULL AND visibility = 'public')
  );

CREATE INDEX idx_skills_bot_conv
  ON pendingbot.skills (bot_id, conversation_id)
  WHERE conversation_id IS NOT NULL;

COMMIT;
