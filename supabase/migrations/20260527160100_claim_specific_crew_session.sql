CREATE OR REPLACE FUNCTION pendingbot.claim_crew_session_for_subject(
  p_runner_host_id uuid,
  p_responsible_subject_id uuid,
  p_crew_session_id uuid,
  p_runner_kinds jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  host_row pendingbot.runner_hosts%ROWTYPE;
  session_row pendingbot.crew_sessions%ROWTYPE;
  lease_id uuid;
BEGIN
  SELECT *
    INTO host_row
    FROM pendingbot.runner_hosts
   WHERE id = p_runner_host_id
     AND responsible_subject_id = p_responsible_subject_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'runner host not found' USING ERRCODE = 'P0002';
  END IF;

  IF host_row.status = 'disabled' THEN
    RAISE EXCEPTION 'runner host disabled' USING ERRCODE = '42501';
  END IF;

  UPDATE pendingbot.runner_hosts
     SET status = 'online',
         last_seen_at = now(),
         updated_at = now()
   WHERE id = p_runner_host_id;

  SELECT cs.*
    INTO session_row
    FROM pendingbot.crew_sessions cs
   WHERE cs.id = p_crew_session_id
     AND cs.responsible_subject_id = p_responsible_subject_id
     AND cs.status = 'queued'
     AND host_row.allowed_runner_kinds ? cs.runner_kind
     AND (
       p_runner_kinds IS NULL
       OR jsonb_typeof(p_runner_kinds) <> 'array'
       OR jsonb_array_length(p_runner_kinds) = 0
       OR p_runner_kinds ? cs.runner_kind
     )
     AND NOT EXISTS (
       SELECT 1
         FROM pendingbot.runner_leases rl
        WHERE rl.crew_session_id = cs.id
          AND rl.lease_status = 'active'
          AND rl.expires_at > now()
     )
   FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  lease_id := pendingbot.uuidv7();

  INSERT INTO pendingbot.runner_leases(
    id,
    crew_session_id,
    runner_host_id,
    responsible_subject_id,
    lease_status,
    granted_by_user_id,
    lease_token_hash,
    expires_at
  ) VALUES (
    lease_id,
    session_row.id,
    host_row.id,
    session_row.responsible_subject_id,
    'active',
    NULL,
    md5(lease_id::text || ':' || clock_timestamp()::text),
    now() + interval '15 minutes'
  );

  UPDATE pendingbot.crew_sessions
     SET status = 'running',
         runner_host_id = host_row.id,
         started_at = COALESCE(started_at, now()),
         progress_summary = '正在运行',
         updated_at = now()
   WHERE id = session_row.id
   RETURNING * INTO session_row;

  INSERT INTO pendingbot.session_events(
    crew_session_id,
    event_type,
    visibility,
    summary,
    payload
  ) VALUES (
    session_row.id,
    'started',
    'crew_members',
    'Runner 已认领 session',
    jsonb_build_object('runner_host_id', host_row.id, 'runner_kind', session_row.runner_kind)
  );

  RETURN jsonb_build_object(
    'lease_id', lease_id,
    'session', jsonb_build_object(
      'id', session_row.id,
      'crew_conversation_id', session_row.crew_conversation_id,
      'responsible_subject_id', session_row.responsible_subject_id,
      'runner_kind', session_row.runner_kind,
      'status', session_row.status,
      'task_brief', session_row.task_brief,
      'progress_summary', session_row.progress_summary,
      'created_at', session_row.created_at,
      'started_at', session_row.started_at,
      'finished_at', session_row.finished_at
    )
  );
END $$;

ALTER FUNCTION pendingbot.claim_crew_session_for_subject(uuid, uuid, uuid, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.claim_crew_session_for_subject(uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.claim_crew_session_for_subject(uuid, uuid, uuid, jsonb) TO service_role;
