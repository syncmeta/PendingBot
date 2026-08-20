-- Cross-conv lookback round counter.
--
-- Background: lookback was previously keyed off `conversations.round_count`,
-- so a user who talked to the same bot across many short convs would never
-- hit the per-conv threshold. This table tracks accumulated rounds per
-- (bot, user) pair across ALL their convs; when the counter reaches the
-- configured interval the runner fires and the counter resets to 0.

CREATE TABLE pendingbot.bot_user_lookback_counter (
  bot_id              uuid        NOT NULL REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  user_id             uuid        NOT NULL REFERENCES auth.users(id)     ON DELETE CASCADE,
  rounds_since_last   integer     NOT NULL DEFAULT 0,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bot_id, user_id)
);

ALTER TABLE pendingbot.bot_user_lookback_counter ENABLE ROW LEVEL SECURITY;
-- No policies — only service_role (which bypasses RLS) reads/writes this.

GRANT SELECT, INSERT, UPDATE, DELETE
  ON pendingbot.bot_user_lookback_counter TO service_role;

-- Atomic bump + threshold check + reset. Returns true when the caller
-- should fire a lookback this turn.
CREATE OR REPLACE FUNCTION pendingbot.bump_lookback_counter(
  p_bot      uuid,
  p_user     uuid,
  p_interval integer
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_rounds integer;
BEGIN
  INSERT INTO pendingbot.bot_user_lookback_counter (bot_id, user_id, rounds_since_last)
  VALUES (p_bot, p_user, 1)
  ON CONFLICT (bot_id, user_id) DO UPDATE
    SET rounds_since_last = bot_user_lookback_counter.rounds_since_last + 1,
        updated_at = now()
  RETURNING rounds_since_last INTO v_rounds;

  IF v_rounds >= p_interval THEN
    UPDATE pendingbot.bot_user_lookback_counter
       SET rounds_since_last = 0,
           updated_at = now()
     WHERE bot_id = p_bot AND user_id = p_user;
    RETURN true;
  END IF;
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION pendingbot.bump_lookback_counter(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.bump_lookback_counter(uuid, uuid, integer) TO service_role;
