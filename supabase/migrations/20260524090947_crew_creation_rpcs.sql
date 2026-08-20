-- Crew creation RPCs:
-- - subject-level permission check for creating Crew;
-- - atomic creation of conversation, temporary_group_meta,
--   temporary_group_members, and conversation_participants.

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_create_crew(
  p_subject_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.subjects s
     WHERE s.id = p_subject_id
       AND s.status = 'active'
       AND (
         (s.subject_type = 'user_account' AND s.user_id = p_user_id)
         OR EXISTS (
           SELECT 1
             FROM pendingbot.group_subject_members gsm
            WHERE gsm.subject_id = s.id
              AND gsm.user_id = p_user_id
              AND gsm.can_create_crew = true
         )
       )
  )
$$;

ALTER FUNCTION pendingbot.subject_can_create_crew(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.subject_can_create_crew(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.subject_can_create_crew(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.subject_can_create_crew(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.open_crew_conv(
  p_responsible_subject_id uuid,
  p_title text DEFAULT ''
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  conv_id uuid;
  member_id uuid;
  title_text text;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.subject_can_create_crew(p_responsible_subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot create crew for subject' USING ERRCODE = '42501';
  END IF;

  title_text := NULLIF(trim(COALESCE(p_title, '')), '');
  IF title_text IS NULL THEN
    title_text := 'Crew';
  END IF;

  INSERT INTO pendingbot.conversations(
    conversation_type,
    feature,
    user_id,
    bot_id,
    title,
    metadata
  ) VALUES (
    'crew',
    'message',
    caller_id,
    NULL,
    title_text,
    jsonb_build_object('surface', 'crew')
  )
  RETURNING id INTO conv_id;

  INSERT INTO pendingbot.temporary_group_meta(
    conversation_id,
    temporary_kind,
    responsible_subject_id,
    initiator_type,
    initiator_user_id,
    source_conversation_id,
    parent_temporary_group_id,
    root_temporary_group_id,
    title
  ) VALUES (
    conv_id,
    'crew',
    p_responsible_subject_id,
    'human',
    caller_id,
    NULL,
    NULL,
    conv_id,
    title_text
  );

  INSERT INTO pendingbot.temporary_group_members(
    conversation_id,
    member_kind,
    user_id,
    display_name,
    role,
    capabilities
  )
  SELECT
    conv_id,
    'human',
    caller_id,
    COALESCE(NULLIF(u.display_name, ''), u.email, '你'),
    'owner',
    jsonb_build_object('can_create_session', true, 'can_manage_crew', true)
    FROM pendingbot.users u
   WHERE u.id = caller_id
  RETURNING id INTO member_id;

  IF member_id IS NULL THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.conversation_participants(
    conversation_id,
    participant_type,
    participant_id,
    role
  ) VALUES (
    conv_id,
    'user',
    caller_id,
    'owner'
  )
  ON CONFLICT DO NOTHING;

  RETURN conv_id;
END $$;

ALTER FUNCTION pendingbot.open_crew_conv(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.open_crew_conv(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.open_crew_conv(uuid, text) TO authenticated;

COMMIT;
