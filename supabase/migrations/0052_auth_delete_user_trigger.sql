-- Make `delete from auth.users` work everywhere (Supabase Studio "Delete
-- user", supabase auth admin API, manual SQL) instead of erroring with
-- "Database error deleting user".
--
-- Background. `pendingbot._delete_account_internal(uid)` already does the
-- right cleanup (drops private bots, snips message self-FKs, decouples
-- audit_log/invites/tools, deletes skills/attachments/messages/convs)
-- and ends with `delete from auth.users`. But that cleanup only runs
-- when callers go through the function. Anyone who calls
-- `delete from auth.users` directly — Studio's button, the auth admin
-- API, a quick SQL fix in production — hits ON-DELETE-NO-ACTION on a
-- pile of FKs and gets the error.
--
-- Fix:
--   1. Move the cleanup body into a BEFORE DELETE trigger on auth.users
--      so EVERY delete path gets the same cleanup, regardless of caller.
--   2. Simplify `_delete_account_internal` to a thin wrapper that just
--      runs `delete from auth.users` — the trigger does the work.
--   3. Bring the cleanup current with FKs added since 0002. The new
--      ones from 0033 (redemption_codes.created_by/redeemed_by,
--      billing_ledger.actor_user_id) and 0043
--      (conversation_group_meta.created_by) are all "preserve historical
--      record, just disown" — same shape as audit_log/invites/tools.
--      Easiest way to handle them: switch the FK to ON DELETE SET NULL
--      at the schema level. The trigger doesn't need to know about
--      them.
--
-- Why the trigger over per-FK ALTERs everywhere: a few of the cleanup
-- steps aren't expressible as FK actions — dropping private bots
-- (predicate on visibility), snipping cross-row message self-FKs,
-- deleting conversation_participants by (participant_type, participant_id).
-- A trigger is the natural home for those.

BEGIN;

-- ── FK fixes: tables added after 0002 that block raw delete ──────────

-- conversation_group_meta.created_by: NOT NULL today. Group survives the
-- creator (other members are still in it), so make the column nullable
-- and SET NULL on creator delete.
ALTER TABLE pendingbot.conversation_group_meta
  ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE pendingbot.conversation_group_meta
  DROP CONSTRAINT IF EXISTS conversation_group_meta_created_by_fkey;
ALTER TABLE pendingbot.conversation_group_meta
  ADD CONSTRAINT conversation_group_meta_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- redemption_codes: keep the historical record, just disown.
ALTER TABLE pendingbot.redemption_codes
  DROP CONSTRAINT IF EXISTS redemption_codes_created_by_fkey;
ALTER TABLE pendingbot.redemption_codes
  ADD CONSTRAINT redemption_codes_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.redemption_codes
  DROP CONSTRAINT IF EXISTS redemption_codes_redeemed_by_fkey;
ALTER TABLE pendingbot.redemption_codes
  ADD CONSTRAINT redemption_codes_redeemed_by_fkey
    FOREIGN KEY (redeemed_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- billing_ledger.actor_user_id (admin who issued an adjustment): preserve.
ALTER TABLE pendingbot.billing_ledger
  DROP CONSTRAINT IF EXISTS billing_ledger_actor_user_id_fkey;
ALTER TABLE pendingbot.billing_ledger
  ADD CONSTRAINT billing_ledger_actor_user_id_fkey
    FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- ── BEFORE DELETE trigger function ───────────────────────────────────
-- Body lifted from the 0002 version of _delete_account_internal, minus
-- the final `delete from auth.users` (we ARE the auth-users delete, so
-- recursing would deadlock).
CREATE OR REPLACE FUNCTION pendingbot._before_auth_user_delete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  p_uid uuid := old.id;
  my_conv_ids uuid[];
  my_message_ids uuid[];
begin
  -- Drop private bots created by this user. Cascades bot_invites,
  -- bot_lookbacks, bot_reflections, discuss_settings, skills, review_runs;
  -- conversations.bot_id and messages.sender_bot_id SET NULL so any
  -- preserved cross-user history keeps its referential shape.
  delete from pendingbot.bots
   where creator_id = p_uid and visibility = 'private';

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = p_uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = p_uid or conversation_id = any(my_conv_ids);

  -- Snip self-FKs on other users' messages that point at ours.
  update pendingbot.messages set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  -- Preserve audit_log; decouple user + conv refs.
  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = p_uid;

  -- Preserve invite history.
  update pendingbot.invites set created_by = null where created_by = p_uid;
  update pendingbot.invites set used_by = null where used_by = p_uid;

  -- Preserve tool definitions; disown.
  update pendingbot.tools set owner_id = null where owner_id = p_uid;

  -- NOT-NULL FK rows belonging to the user — must DELETE.
  delete from pendingbot.skills where owner_id = p_uid;
  delete from pendingbot.attachments where user_id = p_uid;

  -- The user's own messages + participants + convs.
  delete from pendingbot.messages where user_id = p_uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = p_uid;
  delete from pendingbot.conversations where user_id = p_uid;

  return old;
end $$;

ALTER FUNCTION pendingbot._before_auth_user_delete() OWNER TO postgres;

DROP TRIGGER IF EXISTS on_auth_user_deleted ON auth.users;
CREATE TRIGGER on_auth_user_deleted
  BEFORE DELETE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot._before_auth_user_delete();

-- ── Slim down _delete_account_internal ───────────────────────────────
-- The cleanup now lives in the trigger; the RPC is just an auth-row
-- delete. Existing callers (finalize_account_deletion, the cron sweep,
-- the board admin "立即彻底删除" button) keep working — they call this
-- function, it deletes the auth row, the trigger fires, cleanup runs.
CREATE OR REPLACE FUNCTION pendingbot._delete_account_internal(p_uid uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
begin
  if p_uid is null then
    raise exception 'p_uid is required';
  end if;
  delete from auth.users where id = p_uid;
end $$;

ALTER FUNCTION pendingbot._delete_account_internal(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._delete_account_internal(uuid) FROM PUBLIC;

COMMIT;
