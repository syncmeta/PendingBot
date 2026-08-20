-- 28-day account-deletion cooldown.
--
-- Old behavior (0042): delete_self_account(p_sentiment) wiped the account
-- on the spot. Too unforgiving — one tap, panic, gone.
--
-- New behavior:
--   1. User taps "去意已决" → request_account_deletion(p_sentiment)
--      stamps pending_deletion_at + pending_deletion_sentiment on
--      pendingbot.users, then iOS signs the user out. Data is intact;
--      the row just carries a tombstone.
--   2. Within 28 days, signing back in calls cancel_account_deletion()
--      which clears the tombstone. Account is fully restored.
--   3. After 28 days, a daily edge cron sweeps all expired tombstones
--      through finalize_account_deletion(p_uid), which logs the captured
--      sentiment to account_deletion_log and runs _delete_account_internal.
--   4. Board admins can call finalize_account_deletion(p_uid, p_force=true)
--      from the user-detail page to wipe immediately (compliance / abuse).
--
-- The sentiment captured at step 1 sticks around in the users row across
-- the cooldown window, so the eventual log entry reflects how the user
-- felt at the moment they decided to leave.

BEGIN;

ALTER TABLE pendingbot.users
  ADD COLUMN pending_deletion_at timestamptz,
  ADD COLUMN pending_deletion_sentiment text,
  ADD CONSTRAINT users_pending_deletion_sentiment_chk
    CHECK (
      pending_deletion_sentiment IS NULL
      OR pending_deletion_sentiment IN ('see_you_again', 'farewell_forever')
    ),
  ADD CONSTRAINT users_pending_deletion_pair_chk
    CHECK (
      (pending_deletion_at IS NULL) = (pending_deletion_sentiment IS NULL)
    );

-- Partial index — cron sweep is the only frequent reader and it filters
-- on NOT NULL. Active users (the bulk of rows) don't need to be indexed.
CREATE INDEX users_pending_deletion_at_idx
  ON pendingbot.users (pending_deletion_at)
  WHERE pending_deletion_at IS NOT NULL;

-- ── Replace immediate-delete RPC ──────────────────────────────────────
DROP FUNCTION IF EXISTS pendingbot.delete_self_account(text);

CREATE OR REPLACE FUNCTION pendingbot.request_account_deletion(p_sentiment text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;
  if p_sentiment is null
     or p_sentiment not in ('see_you_again', 'farewell_forever') then
    raise exception 'invalid sentiment: %', p_sentiment;
  end if;
  update pendingbot.users
     set pending_deletion_at = now(),
         pending_deletion_sentiment = p_sentiment,
         updated_at = now()
   where id = auth.uid();
end $$;

ALTER FUNCTION pendingbot.request_account_deletion(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.request_account_deletion(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.request_account_deletion(text) TO authenticated;

-- ── Cancel-on-login RPC ──────────────────────────────────────────────
-- iOS calls this on every successful sign-in. Returns true iff a tombstone
-- was actually cleared, so the client can show a "已恢复你的账号" banner.
CREATE OR REPLACE FUNCTION pendingbot.cancel_account_deletion()
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  affected int;
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;
  update pendingbot.users
     set pending_deletion_at = null,
         pending_deletion_sentiment = null,
         updated_at = now()
   where id = auth.uid()
     and pending_deletion_at is not null;
  GET DIAGNOSTICS affected = ROW_COUNT;
  return affected > 0;
end $$;

ALTER FUNCTION pendingbot.cancel_account_deletion() OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.cancel_account_deletion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.cancel_account_deletion() TO authenticated;

-- ── Finalize RPC (cron + admin force) ────────────────────────────────
-- Two callers:
--   • edge cron sweep — passes p_force=false; only finalizes rows whose
--     cooldown has expired. Bumps account_deletion_log with the stored
--     sentiment then nukes the user.
--   • board admin "立即彻底删除" — passes p_force=true. If the user
--     already requested deletion we still log their sentiment; if they
--     had no tombstone (raw admin nuke) we skip the log entry — that's
--     an admin action, not a user-driven departure.
CREATE OR REPLACE FUNCTION pendingbot.finalize_account_deletion(
  p_uid uuid,
  p_force boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  pending_at timestamptz;
  sentiment text;
begin
  if p_uid is null then
    raise exception 'p_uid is required';
  end if;
  select pending_deletion_at, pending_deletion_sentiment
    into pending_at, sentiment
    from pendingbot.users where id = p_uid;
  if pending_at is null then
    if not p_force then
      raise exception 'user % has no pending deletion', p_uid;
    end if;
  else
    if not p_force and pending_at + interval '28 days' > now() then
      raise exception 'user % is still in cooldown until %',
                      p_uid, pending_at + interval '28 days';
    end if;
    insert into pendingbot.account_deletion_log (sentiment) values (sentiment);
  end if;
  perform pendingbot._delete_account_internal(p_uid);
end $$;

ALTER FUNCTION pendingbot.finalize_account_deletion(uuid, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.finalize_account_deletion(uuid, boolean) FROM PUBLIC;
-- service_role only — no GRANT to authenticated.
GRANT EXECUTE ON FUNCTION pendingbot.finalize_account_deletion(uuid, boolean) TO service_role;

COMMIT;
