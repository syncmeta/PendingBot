-- Drop the deprecated discuss / surf / portrait features.
--
-- iOS UI and edge runners for these were removed in earlier commits.
-- This migration finishes the cleanup at the DB layer:
--   - migrate any legacy conversation rows still tagged with the dead
--     conversation_type / feature values to user_bot/message so the
--     tightened CHECK constraints below don't reject them
--   - drop the three orphaned tables (discuss_settings / portraits /
--     surf_runs) outright; CASCADE picks up their RLS policies, FKs,
--     and indexes
--   - tighten the conversations CHECK constraints to live values only

UPDATE pendingbot.conversations
   SET conversation_type = 'user_bot',
       feature           = 'message'
 WHERE conversation_type IN ('discuss', 'surf', 'portrait')
    OR feature           IN ('discuss', 'surf', 'portrait');

DROP TABLE IF EXISTS pendingbot.discuss_settings CASCADE;
DROP TABLE IF EXISTS pendingbot.portraits        CASCADE;
DROP TABLE IF EXISTS pendingbot.surf_runs        CASCADE;

ALTER TABLE pendingbot.conversations
  DROP CONSTRAINT IF EXISTS conversations_conversation_type_check;
ALTER TABLE pendingbot.conversations
  ADD  CONSTRAINT conversations_conversation_type_check
       CHECK (conversation_type = ANY (ARRAY[
         'user_bot'::text,
         'user_user'::text,
         'group'::text,
         'self'::text
       ]));

ALTER TABLE pendingbot.conversations
  DROP CONSTRAINT IF EXISTS conversations_feature_check;
ALTER TABLE pendingbot.conversations
  ADD  CONSTRAINT conversations_feature_check
       CHECK (feature = 'message'::text);
