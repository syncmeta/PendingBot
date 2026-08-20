-- scroll_runs.bot_id has carried ON DELETE NO ACTION since 0020, which
-- blocks any bot deletion that has scroll feed rows — and therefore
-- account deletion: the auth.users BEFORE DELETE trigger
-- (_before_auth_user_delete, 0052) drops the user's private bots, and
-- that DELETE trips scroll_runs_bot_id_fkey:
--   update or delete on table "bots" violates foreign key constraint
--   "scroll_runs_bot_id_fkey" on table "scroll_runs"
--
-- Switch to ON DELETE CASCADE — the same shape as the other bot-owned
-- tables (bot_lookbacks, bot_reflections, skills, discuss_settings). A
-- scroll_runs row IS an article produced by a bot; if the bot is gone
-- the article goes with it.

BEGIN;

ALTER TABLE pendingbot.scroll_runs
  DROP CONSTRAINT IF EXISTS scroll_runs_bot_id_fkey;

ALTER TABLE pendingbot.scroll_runs
  ADD CONSTRAINT scroll_runs_bot_id_fkey
    FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE CASCADE;

COMMIT;
