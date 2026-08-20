-- Pin search_path on legacy helper and trigger functions flagged by Supabase
-- advisors. This prevents role-mutable search_path from influencing function
-- name resolution without changing function bodies.

BEGIN;

ALTER FUNCTION pendingbot.gen_preset_handle_value()
  SET search_path = pendingbot, public, pg_catalog;

ALTER FUNCTION pendingbot.uuidv7()
  SET search_path = pendingbot, public, extensions, pg_catalog;

ALTER FUNCTION pendingbot.bootstrap_new_user_trigger()
  SET search_path = pendingbot, public, auth, pg_catalog;

ALTER FUNCTION pendingbot.check_handle_limit()
  SET search_path = pendingbot, public, pg_catalog;

ALTER FUNCTION pendingbot.random_place_name()
  SET search_path = pendingbot, public, pg_catalog;

ALTER FUNCTION pendingbot.bots_guard_public_update()
  SET search_path = pendingbot, public, pg_catalog;

ALTER FUNCTION pendingbot.guard_preset_handle()
  SET search_path = pendingbot, public, pg_catalog;

ALTER FUNCTION pendingbot._group_member_billing_freeze_trigger()
  SET search_path = pendingbot, public, pg_catalog;

COMMIT;
