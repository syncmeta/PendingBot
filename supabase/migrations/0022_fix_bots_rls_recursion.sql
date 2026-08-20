-- Break the RLS cycle between pendingbot.bots and pendingbot.bot_invites.
--
-- bots_visible_read (SELECT on bots) does EXISTS over bot_invites; the
-- bot_invites_creator_all (FOR ALL) policy in turn does EXISTS over bots.
-- Postgres detects the mutual recursion the first time anyone selects a
-- public_invite row and aborts with "infinite recursion detected in policy
-- for relation \"bots\"".
--
-- Fix: lift the invite check on the bots side into a SECURITY DEFINER
-- helper that bypasses RLS for the bot_invites lookup. One side of the
-- loop becomes RLS-free, which is enough to break the cycle.

BEGIN;

CREATE OR REPLACE FUNCTION pendingbot.is_bot_invitee(p_bot_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM pendingbot.bot_invites
    WHERE bot_id = p_bot_id AND user_id = p_user_id
  );
$$;
ALTER FUNCTION pendingbot.is_bot_invitee(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.is_bot_invitee(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.is_bot_invitee(uuid, uuid) TO authenticated;

DROP POLICY IF EXISTS bots_visible_read ON pendingbot.bots;

CREATE POLICY bots_visible_read ON pendingbot.bots FOR SELECT
  USING (
    visibility = 'public_open'
    OR creator_id = auth.uid()
    OR (visibility = 'public_invite'
        AND pendingbot.is_bot_invitee(id, auth.uid()))
  );

COMMIT;
