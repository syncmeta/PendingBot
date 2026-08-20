-- 20260529054705_crew_realtime_triggers.sql
--
-- T4.5 crew live-push. Adds the realtime fan-in triggers for the two
-- crew tables the PendingBot crew chat subscribes to live:
--
--   * crew_announcements — the crew whiteboard / group-chat feed (new
--     messages, post_to_crew, and permission_request cards).
--   * crew_sessions      — session status rows (the inline status strip).
--
-- Both reuse the generic pendingbot.notify_realtime() trigger function
-- from 20260516073714_realtime_webhooks.sql, which POSTs the row change
-- to POST /v1/realtime-internal/notify via pg_net. The edge handler
-- routes these two tables to a `conv:<crew_conversation_id>` hub topic
-- (a crew IS a conversation), which the crew chat already authorizes via
-- resolveConv / the conversations_temporary_group_view RLS policy.
--
-- DEPLOY ORDER: deploy the edge Worker carrying the crew-table routing
-- (realtime-internal.ts CREW_CONV_TABLES) BEFORE pushing this migration.
-- If pushed first, crew_announcements/crew_sessions writes POST into the
-- worker's graceful "table not fanned out" skip (HTTP 200), so it is not
-- fatal — but no fan-out happens until the worker is updated.

create trigger realtime_notify
  after insert or update or delete on pendingbot.crew_announcements
  for each row execute function pendingbot.notify_realtime();

create trigger realtime_notify
  after insert or update or delete on pendingbot.crew_sessions
  for each row execute function pendingbot.notify_realtime();
