-- Crew session RPCs:
-- - only crew conversations can create coding-agent sessions;
-- - creating a session only queues state/events, it does not select or run a runner.

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.open_crew_session(
  p_crew_conversation_id uuid,
  p_runner_kind text,
  p_task_brief text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  meta_row pendingbot.temporary_group_meta%ROWTYPE;
  member_id uuid;
  session_id uuid;
  task_text text;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO meta_row
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_crew_conversation_id
     AND temporary_kind = 'crew'
     AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  IF NOT pendingbot.subject_can_create_crew(meta_row.responsible_subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot create crew session for subject' USING ERRCODE = '42501';
  END IF;

  IF p_runner_kind NOT IN (
    'cloud_sandbox',
    'local_claude_code',
    'local_codex',
    'local_opencode',
    'local_kilo'
  ) THEN
    RAISE EXCEPTION 'invalid runner kind' USING ERRCODE = '22023';
  END IF;

  task_text := trim(COALESCE(p_task_brief, ''));
  IF task_text = '' THEN
    RAISE EXCEPTION 'task brief required' USING ERRCODE = '22023';
  END IF;

  SELECT id
    INTO member_id
    FROM pendingbot.temporary_group_members
   WHERE conversation_id = p_crew_conversation_id
     AND member_kind = 'human'
     AND user_id = caller_id
     AND status = 'active'
   ORDER BY created_at ASC
   LIMIT 1;

  IF member_id IS NULL THEN
    RAISE EXCEPTION 'caller is not an active crew member' USING ERRCODE = '42501';
  END IF;

  INSERT INTO pendingbot.crew_sessions(
    crew_conversation_id,
    responsible_subject_id,
    initiating_member_id,
    runner_kind,
    status,
    task_brief,
    progress_summary
  ) VALUES (
    p_crew_conversation_id,
    meta_row.responsible_subject_id,
    member_id,
    p_runner_kind,
    'queued',
    task_text,
    '已排队'
  )
  RETURNING id INTO session_id;

  INSERT INTO pendingbot.session_events(
    crew_session_id,
    event_type,
    visibility,
    summary,
    payload
  ) VALUES (
    session_id,
    'queued',
    'crew_members',
    '已创建并排队',
    jsonb_build_object('runner_kind', p_runner_kind)
  );

  RETURN session_id;
END $$;

ALTER FUNCTION pendingbot.open_crew_session(uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.open_crew_session(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.open_crew_session(uuid, text, text) TO authenticated;

COMMIT;
