-- Account-deletion sentiment: when a user finalizes account deletion,
-- they pick one of two destructive buttons. The text is identical in
-- effect (account is fully deleted either way), the choice is purely
-- emotional — "去意已决，有缘再见" vs "去意已决，再也不见".
--
-- We log just the choice + timestamp, no user_id / no IP / no email.
-- The row is intentionally orphaned (no FK to auth.users) so it
-- survives the cascading delete in _delete_account_internal — that's
-- the whole point: the user is gone, but the aggregate signal stays.
--
-- Board-only readout: app-stats page totals the two values to show
-- "users who left thinking of coming back" vs "users who slammed the
-- door". Service-role only; no client policy.

BEGIN;

CREATE TABLE pendingbot.account_deletion_log (
    id          uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    sentiment   text NOT NULL,
    deleted_at  timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_deletion_log_pkey PRIMARY KEY (id),
    CONSTRAINT account_deletion_log_sentiment_chk
      CHECK (sentiment IN ('see_you_again', 'farewell_forever'))
);
ALTER TABLE pendingbot.account_deletion_log OWNER TO postgres;

ALTER TABLE pendingbot.account_deletion_log ENABLE ROW LEVEL SECURITY;
-- No policies = no client access. service_role bypasses RLS.

GRANT SELECT, INSERT ON TABLE pendingbot.account_deletion_log TO service_role;

-- Replace the no-arg variant with one that records sentiment first.
-- Keep the no-arg version for one release? No — single env, pre-launch
-- (see project_pre_launch_single_env memory), iOS is the only caller
-- and we ship the matching client in the same merge.
DROP FUNCTION IF EXISTS pendingbot.delete_self_account();

CREATE OR REPLACE FUNCTION pendingbot.delete_self_account(p_sentiment text)
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
  insert into pendingbot.account_deletion_log (sentiment) values (p_sentiment);
  perform pendingbot._delete_account_internal(auth.uid());
end $$;

ALTER FUNCTION pendingbot.delete_self_account(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.delete_self_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.delete_self_account(text) TO authenticated;

COMMIT;
