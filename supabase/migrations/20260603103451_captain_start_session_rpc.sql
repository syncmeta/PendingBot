-- K (spec §6.3.3 captain 职责 "启动 session"): the captain bot can queue a
-- session for its crew. Mirrors open_crew_session_for_subject but the caller is
-- the captain BOT (not a human member): we verify the bot IS the crew's captain
-- and attribute the session to the captain's member row. The session lands
-- status='queued'; the crew's local_host Mac auto-claims + runs it (no human in
-- the loop for the start — the human is chatting with the captain).
--
-- Also inserts the H1 code_session member row so the queued session shows up in
-- the roster immediately.

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.open_crew_session_by_captain(
  p_crew_conversation_id uuid,
  p_captain_bot_id uuid,
  p_task_brief text,
  p_runner_kind text DEFAULT 'local_claude_code'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  meta_row pendingbot.temporary_group_meta%ROWTYPE;
  captain_member_id uuid;
  session_id uuid;
  task_text text;
BEGIN
  SELECT *
    INTO meta_row
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_crew_conversation_id
     AND temporary_kind = 'crew'
     AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  -- Only the crew's own captain may start its sessions.
  IF meta_row.captain_bot_id IS DISTINCT FROM p_captain_bot_id THEN
    RAISE EXCEPTION 'forbidden: only the crew captain can start sessions' USING ERRCODE = '42501';
  END IF;

  task_text := trim(COALESCE(p_task_brief, ''));
  IF task_text = '' THEN
    RAISE EXCEPTION 'task brief required' USING ERRCODE = '22023';
  END IF;

  IF p_runner_kind NOT IN (
    'cloud_sandbox', 'local_claude_code', 'local_codex', 'local_opencode', 'local_kilo'
  ) THEN
    RAISE EXCEPTION 'invalid runner kind' USING ERRCODE = '22023';
  END IF;

  -- The captain's own member row (member_kind='captain') is the initiator.
  SELECT id
    INTO captain_member_id
    FROM pendingbot.temporary_group_members
   WHERE conversation_id = p_crew_conversation_id
     AND member_kind = 'captain'
     AND bot_id = p_captain_bot_id
     AND status = 'active'
   ORDER BY created_at ASC
   LIMIT 1;
  IF captain_member_id IS NULL THEN
    RAISE EXCEPTION 'captain member row not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.crew_sessions(
    crew_conversation_id, responsible_subject_id, initiating_member_id,
    runner_kind, status, task_brief, progress_summary
  ) VALUES (
    p_crew_conversation_id, meta_row.responsible_subject_id, captain_member_id,
    p_runner_kind, 'queued', task_text, '已排队（机长发起）'
  )
  RETURNING id INTO session_id;

  -- H1: the queued session joins the crew group as a member.
  INSERT INTO pendingbot.temporary_group_members(
    conversation_id, member_kind, code_session_id, display_name, role, status
  ) VALUES (
    p_crew_conversation_id, 'code_session', session_id,
    left(task_text, 40), 'member', 'active'
  );

  INSERT INTO pendingbot.session_events(
    crew_session_id, event_type, visibility, summary, payload
  ) VALUES (
    session_id, 'queued', 'crew_members', '机长已创建并排队',
    jsonb_build_object('runner_kind', p_runner_kind, 'by_captain', true)
  );

  RETURN session_id;
END $$;

ALTER FUNCTION pendingbot.open_crew_session_by_captain(uuid, uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.open_crew_session_by_captain(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.open_crew_session_by_captain(uuid, uuid, text, text) TO service_role;

COMMIT;
