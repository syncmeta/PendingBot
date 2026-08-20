-- Runner session claim RPCs:
-- - runner hosts can claim one queued Crew session at a time;
-- - claimed runners can append structured events;
-- - claimed runners can finish sessions and release leases.

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.claim_next_crew_session(
  p_runner_host_id uuid,
  p_runner_kinds jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  host_row pendingbot.runner_hosts%ROWTYPE;
  session_row pendingbot.crew_sessions%ROWTYPE;
  lease_id uuid;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO host_row
    FROM pendingbot.runner_hosts
   WHERE id = p_runner_host_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'runner host not found' USING ERRCODE = 'P0002';
  END IF;

  IF host_row.status = 'disabled' THEN
    RAISE EXCEPTION 'runner host disabled' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.subject_can_manage_runners(host_row.responsible_subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot manage runner host' USING ERRCODE = '42501';
  END IF;

  UPDATE pendingbot.runner_hosts
     SET status = 'online',
         last_seen_at = now(),
         updated_at = now()
   WHERE id = p_runner_host_id;

  SELECT cs.*
    INTO session_row
    FROM pendingbot.crew_sessions cs
   WHERE cs.responsible_subject_id = host_row.responsible_subject_id
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
   ORDER BY cs.created_at ASC
   FOR UPDATE SKIP LOCKED
   LIMIT 1;

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
    caller_id,
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

ALTER FUNCTION pendingbot.claim_next_crew_session(uuid, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.claim_next_crew_session(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.claim_next_crew_session(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION pendingbot.append_crew_session_event_from_runner(
  p_runner_host_id uuid,
  p_crew_session_id uuid,
  p_event_type text,
  p_visibility text DEFAULT 'crew_members',
  p_summary text DEFAULT '',
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_progress_summary text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  session_row pendingbot.crew_sessions%ROWTYPE;
  event_id uuid;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_crew_session_id
     AND runner_host_id = p_runner_host_id
     AND status IN ('running', 'waiting_permission', 'blocked');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew session not found for runner host' USING ERRCODE = 'P0002';
  END IF;

  IF NOT pendingbot.subject_can_manage_runners(session_row.responsible_subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot manage runner host' USING ERRCODE = '42501';
  END IF;

  IF p_event_type NOT IN (
    'started',
    'context_injected',
    'status',
    'tool_call',
    'tool_result',
    'permission_requested',
    'permission_resolved',
    'artifact_created',
    'posted_to_crew',
    'blocked'
  ) THEN
    RAISE EXCEPTION 'invalid event type' USING ERRCODE = '22023';
  END IF;

  IF p_visibility NOT IN ('controllers', 'crew_members', 'private_system') THEN
    RAISE EXCEPTION 'invalid event visibility' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pendingbot.runner_leases rl
     WHERE rl.crew_session_id = p_crew_session_id
       AND rl.runner_host_id = p_runner_host_id
       AND rl.lease_status = 'active'
       AND rl.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'forbidden: runner lease is not active' USING ERRCODE = '42501';
  END IF;

  INSERT INTO pendingbot.session_events(
    crew_session_id,
    event_type,
    visibility,
    summary,
    payload
  ) VALUES (
    p_crew_session_id,
    p_event_type,
    p_visibility,
    NULLIF(trim(COALESCE(p_summary, '')), ''),
    COALESCE(p_payload, '{}'::jsonb)
  )
  RETURNING id INTO event_id;

  UPDATE pendingbot.crew_sessions
     SET progress_summary = COALESCE(NULLIF(trim(COALESCE(p_progress_summary, '')), ''), progress_summary),
         status = CASE WHEN p_event_type = 'blocked' THEN 'blocked' ELSE status END,
         updated_at = now()
   WHERE id = p_crew_session_id;

  UPDATE pendingbot.runner_hosts
     SET status = 'online',
         last_seen_at = now(),
         updated_at = now()
   WHERE id = p_runner_host_id
     AND status <> 'disabled';

  RETURN event_id;
END $$;

ALTER FUNCTION pendingbot.append_crew_session_event_from_runner(uuid, uuid, text, text, text, jsonb, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.append_crew_session_event_from_runner(uuid, uuid, text, text, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.append_crew_session_event_from_runner(uuid, uuid, text, text, text, jsonb, text) TO authenticated;

CREATE OR REPLACE FUNCTION pendingbot.finish_crew_session_from_runner(
  p_runner_host_id uuid,
  p_crew_session_id uuid,
  p_status text,
  p_summary text DEFAULT '',
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_progress_summary text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  session_row pendingbot.crew_sessions%ROWTYPE;
  final_summary text;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('completed', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'invalid final status' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_crew_session_id
     AND runner_host_id = p_runner_host_id
     AND status IN ('running', 'waiting_permission', 'blocked');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew session not found for runner host' USING ERRCODE = 'P0002';
  END IF;

  IF NOT pendingbot.subject_can_manage_runners(session_row.responsible_subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot manage runner host' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pendingbot.runner_leases rl
     WHERE rl.crew_session_id = p_crew_session_id
       AND rl.runner_host_id = p_runner_host_id
       AND rl.lease_status = 'active'
       AND rl.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'forbidden: runner lease is not active' USING ERRCODE = '42501';
  END IF;

  final_summary := NULLIF(trim(COALESCE(p_summary, '')), '');

  UPDATE pendingbot.crew_sessions
     SET status = p_status,
         progress_summary = COALESCE(
           NULLIF(trim(COALESCE(p_progress_summary, '')), ''),
           final_summary,
           progress_summary
         ),
         finished_at = now(),
         updated_at = now()
   WHERE id = p_crew_session_id;

  UPDATE pendingbot.runner_leases
     SET lease_status = 'released',
         released_at = now()
   WHERE crew_session_id = p_crew_session_id
     AND runner_host_id = p_runner_host_id
     AND lease_status = 'active';

  INSERT INTO pendingbot.session_events(
    crew_session_id,
    event_type,
    visibility,
    summary,
    payload
  ) VALUES (
    p_crew_session_id,
    p_status,
    'crew_members',
    final_summary,
    COALESCE(p_payload, '{}'::jsonb)
  );

  UPDATE pendingbot.runner_hosts
     SET status = 'online',
         last_seen_at = now(),
         updated_at = now()
   WHERE id = p_runner_host_id
     AND status <> 'disabled';

  RETURN true;
END $$;

ALTER FUNCTION pendingbot.finish_crew_session_from_runner(uuid, uuid, text, text, jsonb, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.finish_crew_session_from_runner(uuid, uuid, text, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.finish_crew_session_from_runner(uuid, uuid, text, text, jsonb, text) TO authenticated;

COMMIT;

