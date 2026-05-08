-- Drop the review six-card feature.
--
-- The edge route, runner, and prompt were removed; nothing writes to
-- review_runs or bot_reflections anymore, and no client ever consumed
-- them either. CASCADE picks up the indexes, RLS policies, FKs, and
-- the supabase_realtime publication entry for review_runs.

DROP TABLE IF EXISTS pendingbot.bot_reflections CASCADE;
DROP TABLE IF EXISTS pendingbot.review_runs    CASCADE;
