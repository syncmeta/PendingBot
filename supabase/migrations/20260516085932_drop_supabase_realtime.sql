-- 20260516085932_drop_supabase_realtime.sql
--
-- Tear down the Supabase Realtime era. The iOS client no longer uses
-- Supabase Realtime — realtime delivery runs over the Cloudflare hub
-- (see 20260516073714_realtime_webhooks.sql). This removes the two
-- now-dead pieces:
--
--   1. Every pendingbot table is dropped from the `supabase_realtime`
--      publication, so Postgres stops doing WAL work for a stream
--      nothing consumes. DROP TABLE rather than DROP PUBLICATION — the
--      publication is Supabase-managed and may back other features.
--   2. messages.content_partial is dropped. It backed the original
--      "stream the reply by updating one row in place" design, which
--      was never implemented — the worker emits whole bubbles as
--      separate INSERTs and never writes content_partial. Dead column
--      (content_tsv is generated from `content`, not this one).
--
-- Push together with the realtime cutover — see docs/deploy.md.

alter publication supabase_realtime drop table
  pendingbot.conversations,
  pendingbot.conversation_participants,
  pendingbot.messages,
  pendingbot.user_unread_counts,
  pendingbot.bot_lookbacks,
  pendingbot.scroll_runs,
  pendingbot.group_continue_requests;

alter table pendingbot.messages drop column content_partial;
