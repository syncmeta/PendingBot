-- Human help request RPCs:
-- - requested user can accept or decline a bot-created help request;
-- - accepting joins the human into the temporary group.

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.decide_human_help_request(
  p_request_id uuid,
  p_decision text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  req_row pendingbot.human_help_requests%ROWTYPE;
  display_text text;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  IF p_decision NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid decision' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO req_row
    FROM pendingbot.human_help_requests
   WHERE id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'help request not found' USING ERRCODE = 'P0002';
  END IF;

  IF req_row.requested_user_id <> caller_id THEN
    RAISE EXCEPTION 'forbidden: request is not yours' USING ERRCODE = '42501';
  END IF;

  IF req_row.status <> 'pending' THEN
    RAISE EXCEPTION 'help request already decided' USING ERRCODE = '22023';
  END IF;

  UPDATE pendingbot.human_help_requests
     SET status = p_decision,
         decided_at = now()
   WHERE id = p_request_id;

  IF p_decision = 'accepted' THEN
    SELECT COALESCE(NULLIF(display_name, ''), email, '你')
      INTO display_text
      FROM pendingbot.users
     WHERE id = caller_id;

    INSERT INTO pendingbot.temporary_group_members(
      conversation_id,
      member_kind,
      user_id,
      display_name,
      role,
      invited_by_member_id
    )
    SELECT
      req_row.temporary_group_id,
      'human',
      caller_id,
      COALESCE(display_text, '你'),
      'member',
      req_row.requester_member_id
    WHERE NOT EXISTS (
      SELECT 1
        FROM pendingbot.temporary_group_members existing
       WHERE existing.conversation_id = req_row.temporary_group_id
         AND existing.member_kind = 'human'
         AND existing.user_id = caller_id
         AND existing.status = 'active'
    );

    INSERT INTO pendingbot.conversation_participants(
      conversation_id,
      participant_type,
      participant_id,
      role
    ) VALUES (
      req_row.temporary_group_id,
      'user',
      caller_id,
      'member'
    )
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN true;
END $$;

ALTER FUNCTION pendingbot.decide_human_help_request(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.decide_human_help_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.decide_human_help_request(uuid, text) TO authenticated;

COMMIT;
