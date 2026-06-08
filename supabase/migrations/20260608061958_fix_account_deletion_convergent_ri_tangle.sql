-- Account deletion, part 2: kill the convergent-FK RI tangle at the
-- auth.users level. (Part 1 = 20260608051247, which gave the subject subtree
-- deliberate ON DELETE actions — necessary, but not sufficient.)
--
-- Root cause (found by reproduction, not theory):
--   * Deleting the personal SUBJECT alone cascades CLEANLY (verified by a
--     rolled-back `delete from pendingbot.subjects where id=…`).
--   * Deleting the AUTH.USERS row still throws
--     `insert or update on table "subject_device_login_challenges" violates
--      ..._issued_grant_fkey (23503)`.
--   The difference is the auth.users-level SET NULL paths. A device-login
--   challenge has THREE refs into the deletion closure — approved_by_user_id
--   -> auth.users (SET NULL), approved_subject_id -> subjects (SET NULL), and
--   issued_grant_id -> subject_device_grants (CASCADE, via the subject). When
--   `delete from auth.users` fires all RI actions in ONE statement, the row is
--   simultaneously SET-NULL'd (approved_by_user_id) and CASCADE-deleted (its
--   grant goes with the subject) — Postgres re-validates the FK mid-cascade
--   and trips 23503. A pure FK-action change can't fix a *write* to the row
--   during the cascade.
--
-- The same convergent pattern (one row with both a CASCADE and a SET NULL FK
-- to the deleted user) exists on exactly four tables referencing the user:
-- subjects, user_bot_contacts, group_join_requests, group_subject_members
-- (audited across the whole schema). subjects also drags the device
-- challenges + crew_sessions (CASCADE via subject + SET NULL via member) into
-- the tangle.
--
-- Fix: pre-delete those rows in the BEFORE DELETE trigger — exactly the device
-- 0052 already uses for cleanup that FK actions can't express. Running before
-- the auth.users row is gone, each is a clean single-path delete, so nothing
-- convergent survives into the cascade. Deleting the personal subject here
-- also runs its (now-clean, post-part-1) subtree cascade in isolation, so the
-- auth.users-level SET NULL paths later hit zero rows.
--
-- Verified: rolled-back simulation of all four pre-deletes for the real
-- blocked account 617259ec returns clean.

CREATE OR REPLACE FUNCTION pendingbot._before_auth_user_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
declare
  p_uid uuid := old.id;
  my_conv_ids uuid[];
  my_message_ids uuid[];
begin
  delete from pendingbot.bots
   where creator_id = p_uid and visibility = 'private';

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = p_uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = p_uid or conversation_id = any(my_conv_ids);

  update pendingbot.messages set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = p_uid;

  update pendingbot.invites set created_by = null where created_by = p_uid;
  update pendingbot.invites set used_by = null where used_by = p_uid;

  -- (legacy `update pendingbot.tools set owner_id = null` removed —
  -- the new tools table has no owner concept; entries are global.)

  delete from pendingbot.skills where owner_id = p_uid;
  delete from pendingbot.attachments where user_id = p_uid;

  delete from pendingbot.messages where user_id = p_uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = p_uid;
  delete from pendingbot.conversations where user_id = p_uid;

  -- ── Convergent-FK rows: pre-delete to avoid the multi-path RI tangle ──
  -- These four tables each have a row that the auth.users delete would BOTH
  -- CASCADE-delete and SET NULL in one statement (see header). Removing them
  -- here, single-path, before the cascade, prevents 23503.
  delete from pendingbot.user_bot_contacts     where user_id = p_uid;
  delete from pendingbot.group_join_requests   where requester_id = p_uid;
  delete from pendingbot.group_subject_members where user_id = p_uid;

  -- Personal subject = the whole subject subtree (device grants/challenges,
  -- crew_sessions, runner_leases, wallets, pnc_ledger, …). Its cascade is
  -- clean after migration 20260608051247; running it here means the
  -- auth.users-level SET NULL paths on those tables hit zero rows.
  delete from pendingbot.subjects where user_id = p_uid;

  return old;
end $function$;

ALTER FUNCTION pendingbot._before_auth_user_delete() OWNER TO postgres;
