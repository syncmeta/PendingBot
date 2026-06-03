-- Fix: create_interaction_request (T4.5) and create_permission_request (T4.3)
-- both INSERT a mirror row into pendingbot.messages WITHOUT a client_message_id,
-- but that column is NOT NULL UNIQUE with no default. Neither RPC had ever been
-- exercised at runtime until the T4.5 ask_human E2E — which surfaced as an
-- opaque HTTP 500 (the edge create route maps any RPC error to database_error).
--
-- This migration CREATE-OR-REPLACEs both functions, adding
--   client_message_id := gen_random_uuid()
-- to the messages INSERT. It does NOT edit the already-applied source migrations
-- (20260528151836 / 20260603032138) — replacing in a fresh migration keeps the
-- ledger honest. Function bodies are otherwise byte-identical to those migrations.

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- T4.3 — create_permission_request (messages INSERT now carries client_message_id)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pendingbot.create_permission_request(
  p_session_id uuid,
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_risk_level text DEFAULT 'medium'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  session_row pendingbot.crew_sessions%ROWTYPE;
  action_text text;
  risk_text text;
  new_request_id uuid;
  announcement_payload jsonb;
  summary_text text;
BEGIN
  IF caller_id IS NOT NULL THEN
    RAISE EXCEPTION 'forbidden: create_permission_request is service-role only' USING ERRCODE = '42501';
  END IF;

  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'session id required' USING ERRCODE = '22023';
  END IF;
  action_text := NULLIF(trim(COALESCE(p_action, '')), '');
  IF action_text IS NULL THEN
    RAISE EXCEPTION 'action required' USING ERRCODE = '22023';
  END IF;

  risk_text := COALESCE(NULLIF(trim(p_risk_level), ''), 'medium');
  IF risk_text NOT IN ('low', 'medium', 'high') THEN
    RAISE EXCEPTION 'invalid risk_level' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.permission_requests(
    crew_session_id,
    responsible_subject_id,
    requested_action,
    risk_level,
    detail,
    status
  ) VALUES (
    session_row.id,
    session_row.responsible_subject_id,
    action_text,
    risk_text,
    COALESCE(p_payload, '{}'::jsonb),
    'pending'
  )
  RETURNING id INTO new_request_id;

  summary_text := substr(action_text, 1, 140);
  announcement_payload := jsonb_build_object(
    'permission_request_id', new_request_id,
    'action', action_text,
    'risk_level', risk_text,
    'detail', COALESCE(p_payload, '{}'::jsonb),
    'status', 'pending'
  );

  INSERT INTO pendingbot.crew_announcements(
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_session_id,
    recipient_mode,
    message_kind,
    board_visible,
    summary,
    payload,
    created_by_user_id
  ) VALUES (
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    'session',
    session_row.id,
    'all_sessions',
    'permission_request',
    true,
    summary_text,
    announcement_payload,
    NULL
  );

  INSERT INTO pendingbot.messages(
    conversation_id,
    client_message_id,
    role,
    log_kind,
    log_payload,
    content,
    status
  ) VALUES (
    session_row.crew_conversation_id,
    gen_random_uuid(),
    'log',
    'permission_request',
    announcement_payload,
    summary_text,
    'done'
  );

  RETURN new_request_id;
END $$;

-- ────────────────────────────────────────────────────────────────────
-- T4.5 — create_interaction_request (messages INSERT now carries client_message_id)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pendingbot.create_interaction_request(
  p_session_id uuid,
  p_question text,
  p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  session_row pendingbot.crew_sessions%ROWTYPE;
  question_text text;
  new_request_id uuid;
  announcement_payload jsonb;
  summary_text text;
BEGIN
  IF caller_id IS NOT NULL THEN
    RAISE EXCEPTION 'forbidden: create_interaction_request is service-role only' USING ERRCODE = '42501';
  END IF;

  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'session id required' USING ERRCODE = '22023';
  END IF;
  question_text := NULLIF(trim(COALESCE(p_question, '')), '');
  IF question_text IS NULL THEN
    RAISE EXCEPTION 'question required' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.permission_requests(
    crew_session_id,
    responsible_subject_id,
    requested_action,
    request_kind,
    risk_level,
    detail,
    status
  ) VALUES (
    session_row.id,
    session_row.responsible_subject_id,
    question_text,
    'question',
    'low',
    COALESCE(p_payload, '{}'::jsonb),
    'pending'
  )
  RETURNING id INTO new_request_id;

  summary_text := substr(question_text, 1, 140);
  announcement_payload := jsonb_build_object(
    'permission_request_id', new_request_id,
    'kind', 'interaction',
    'question', question_text,
    'detail', COALESCE(p_payload, '{}'::jsonb),
    'status', 'pending'
  );

  INSERT INTO pendingbot.crew_announcements(
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_session_id,
    recipient_mode,
    message_kind,
    board_visible,
    summary,
    payload,
    created_by_user_id
  ) VALUES (
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    'session',
    session_row.id,
    'all_sessions',
    'permission_request',
    true,
    summary_text,
    announcement_payload,
    NULL
  );

  INSERT INTO pendingbot.messages(
    conversation_id,
    client_message_id,
    role,
    log_kind,
    log_payload,
    content,
    status
  ) VALUES (
    session_row.crew_conversation_id,
    gen_random_uuid(),
    'log',
    'permission_request',
    announcement_payload,
    summary_text,
    'done'
  );

  RETURN new_request_id;
END $$;

COMMIT;
