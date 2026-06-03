-- T4.5 交互（Human-in-the-loop Interaction），spec v2 §10 重写后的数据面。
--
-- 把 permission_requests 复用成"交互请求"的载体：一个 session 跑的 agent
-- 经 `ask_human` MCP 工具发起交互（问问题 / 要授权 / 要判断），阻塞等人答；
-- 人在交互卡里回**自由文本**（不只是 approve/reject），agent 的工具拿到回复
-- 继续跑。区别于 T4.3 的纯 approve/reject permission card。
--
-- 本迁移：
--   1) permission_requests 加 `request_kind`（permission|question）+ `reply_text`
--   2) RPC create_interaction_request(p_session_id, p_question, p_payload)
--      —— 仿 create_permission_request，落 question 行 + 发交互卡，返回 id
--   3) RPC answer_interaction_request(p_id, p_reply_text, p_caller_user_id)
--      —— 仿 decide_permission_request 的 ACL，存 reply_text + status='answered'
--
-- 溯源/captain 自决（spec §10.3-10.5）暂不在 DB 层做：v1 直接把卡发给责任
-- 主体（direct_to_human），captain LLM 三角判断 + 沿 DAG 层层审批留 follow-up。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) permission_requests: request_kind + reply_text
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.permission_requests
  ADD COLUMN IF NOT EXISTS request_kind text NOT NULL DEFAULT 'permission';

ALTER TABLE pendingbot.permission_requests
  DROP CONSTRAINT IF EXISTS permission_requests_request_kind_check;
ALTER TABLE pendingbot.permission_requests
  ADD CONSTRAINT permission_requests_request_kind_check
  CHECK (request_kind IN ('permission', 'question'));

ALTER TABLE pendingbot.permission_requests
  ADD COLUMN IF NOT EXISTS reply_text text NULL;

-- Extend the status set with 'answered' (the terminal state for a question
-- interaction; permission rows keep using approved/denied).
ALTER TABLE pendingbot.permission_requests
  DROP CONSTRAINT IF EXISTS permission_requests_status_check;
ALTER TABLE pendingbot.permission_requests
  ADD CONSTRAINT permission_requests_status_check
  CHECK (status IN ('pending', 'approved', 'denied', 'expired', 'cancelled', 'answered'));

COMMENT ON COLUMN pendingbot.permission_requests.request_kind IS
  'spec v2 §10: permission = T4.3 approve/reject 门禁; question = T4.5 交互（ask_human，自由文本回复）。';
COMMENT ON COLUMN pendingbot.permission_requests.reply_text IS
  'spec v2 §10: question 类交互的人类自由文本回复。answer_interaction_request 写入。';

-- crew_announcements / messages.log 的 card 复用 permission_request 的 message_kind/
-- log_kind（卡片渲染同一套），靠 payload.kind 区分 permission vs interaction。

-- ────────────────────────────────────────────────────────────────────
-- 2) RPC create_interaction_request
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.create_interaction_request(uuid, text, jsonb);

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
  -- Service-role only: called by the edge worker on behalf of the runner's
  -- ask_human MCP tool. Authenticated users answer (not create) via
  -- answer_interaction_request.
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

  -- Mirror onto the crew whiteboard as an interaction card (same card surface
  -- as permission_request; payload.kind distinguishes it).
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
    role,
    log_kind,
    log_payload,
    content,
    status
  ) VALUES (
    session_row.crew_conversation_id,
    'log',
    'permission_request',
    announcement_payload,
    summary_text,
    'done'
  );

  RETURN new_request_id;
END $$;

ALTER FUNCTION pendingbot.create_interaction_request(uuid, text, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_interaction_request(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_interaction_request(uuid, text, jsonb) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 3) RPC answer_interaction_request
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.answer_interaction_request(uuid, text, uuid);

CREATE OR REPLACE FUNCTION pendingbot.answer_interaction_request(
  p_id uuid,
  p_reply_text text,
  p_caller_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  req_row pendingbot.permission_requests%ROWTYPE;
  subject_row pendingbot.subjects%ROWTYPE;
  reply_clean text;
  current_caller uuid := auth.uid();
  effective_caller uuid;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'interaction request id required' USING ERRCODE = '22023';
  END IF;

  -- Same caller-resolution as decide_permission_request: an authenticated
  -- user must match p_caller_user_id; service-role trusts the passed id (the
  -- edge worker resolves the real caller first).
  IF current_caller IS NOT NULL THEN
    IF p_caller_user_id IS DISTINCT FROM current_caller THEN
      RAISE EXCEPTION 'caller user id mismatch' USING ERRCODE = '42501';
    END IF;
    effective_caller := current_caller;
  ELSE
    IF p_caller_user_id IS NULL THEN
      RAISE EXCEPTION 'caller user id required' USING ERRCODE = '22023';
    END IF;
    effective_caller := p_caller_user_id;
  END IF;

  reply_clean := COALESCE(p_reply_text, '');

  SELECT *
    INTO req_row
    FROM pendingbot.permission_requests
   WHERE id = p_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'interaction request not found' USING ERRCODE = 'P0002';
  END IF;

  IF req_row.request_kind <> 'question' THEN
    RAISE EXCEPTION 'not an interaction request (use decide_permission_request)' USING ERRCODE = '22023';
  END IF;
  IF req_row.status <> 'pending' THEN
    RAISE EXCEPTION 'interaction request already answered' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO subject_row
    FROM pendingbot.subjects
   WHERE id = req_row.responsible_subject_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'responsible subject missing' USING ERRCODE = 'P0002';
  END IF;

  -- Same ACL as decide_permission_request.
  IF subject_row.subject_type = 'user_account' THEN
    IF subject_row.user_id IS DISTINCT FROM effective_caller THEN
      RAISE EXCEPTION 'forbidden: only subject owner can answer' USING ERRCODE = '42501';
    END IF;
  ELSIF subject_row.subject_type = 'group_account' THEN
    IF NOT pendingbot.subject_user_has_role(
      subject_row.id,
      effective_caller,
      ARRAY['owner', 'admin']
    ) THEN
      RAISE EXCEPTION 'forbidden: owner or admin required' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'unsupported subject_type' USING ERRCODE = '22023';
  END IF;

  UPDATE pendingbot.permission_requests
     SET status = 'answered',
         reply_text = reply_clean,
         decided_at = now(),
         decided_by_user_id = effective_caller
   WHERE id = p_id;
END $$;

ALTER FUNCTION pendingbot.answer_interaction_request(uuid, text, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.answer_interaction_request(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.answer_interaction_request(uuid, text, uuid) TO service_role;

COMMIT;
