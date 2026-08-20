-- T4.3 P0 — Permission Request 自动/手动模式(spec v2 §10)。
--
-- 现状摘要(不重建):
--   * pendingbot.permission_requests 表 — 由 20260524090046_crew_dispatch_schema.sql 创建。
--     现有列:id / crew_session_id / responsible_subject_id / requested_action /
--             risk_level / detail / status / requested_at / decided_by_user_id /
--             decided_at。RLS 已开,view policy 已就位。
--   * pendingbot.crew_announcements + crew_announcement_mentions — 群聊白板事实源。
--     现有 message_kind check 约束:announcement/instruction/status/question/handoff/result/blocker。
--   * pendingbot.session_mailbox_items.message_kind 同样的 7 个值。
--
-- 本次新增,围绕 spec v2 §10 "Permission Request":
--
--   1) temporary_group_meta.permission_mode text 'auto'|'manual' default 'auto'
--      — crew 级默认 permission 模式。
--   2) crew_sessions.permission_mode_override text 'auto'|'manual'|null default null
--      — session 级覆盖,null 表示继承 crew 默认。
--   3) crew_announcements.message_kind 扩 + 'permission_request'(用来在白板上挂"特殊卡片")。
--      session_mailbox_items.message_kind 同步扩 + 'permission_request'。
--   4) RPC `create_permission_request(p_session_id, p_action, p_payload, p_risk_level?)` returns uuid
--      — 由 service_role 调(走 edge service-role client),记 permission_requests 行 +
--      写一条 message_kind='permission_request' 的 crew announcement(板上),不进 mailbox
--      (不需要打扰其他 session;此卡片是给"群里人类"看的)。
--      Returns:新 permission_requests.id。
--   5) RPC `decide_permission_request(p_id, p_decision, p_caller_user_id?)` returns void
--      — 由 edge 端调,p_decision 限 'approve'|'reject';映射到 status 'approved'/'denied'。
--      校验:caller_user_id 必须对 crew 的 responsible_subject 有"批 perm 的权限"。
--      v1 简化:
--        * user_account 责任主体 — 该 user 自己才能批
--        * group_account 责任主体 — owner 或 admin(role IN ('owner','admin'))
--      （spec v2 §4.3,member 不能批 perm request。后续可在此 RPC 内细化。）
--      只允许从 'pending' 转走;已 decided 抛 P0002。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) temporary_group_meta.permission_mode
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.temporary_group_meta
  ADD COLUMN IF NOT EXISTS permission_mode text NOT NULL DEFAULT 'auto';

ALTER TABLE pendingbot.temporary_group_meta
  DROP CONSTRAINT IF EXISTS temporary_group_meta_permission_mode_check;
ALTER TABLE pendingbot.temporary_group_meta
  ADD CONSTRAINT temporary_group_meta_permission_mode_check
  CHECK (permission_mode IN ('auto', 'manual'));

COMMENT ON COLUMN pendingbot.temporary_group_meta.permission_mode IS
  'spec v2 §10: crew 级默认 permission 模式。auto = agent 自由执行(默认),manual = 高危操作要 request_permission 弹卡片。可被 crew_sessions.permission_mode_override 覆盖。';

-- ────────────────────────────────────────────────────────────────────
-- 2) crew_sessions.permission_mode_override
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.crew_sessions
  ADD COLUMN IF NOT EXISTS permission_mode_override text NULL;

ALTER TABLE pendingbot.crew_sessions
  DROP CONSTRAINT IF EXISTS crew_sessions_permission_mode_override_check;
ALTER TABLE pendingbot.crew_sessions
  ADD CONSTRAINT crew_sessions_permission_mode_override_check
  CHECK (permission_mode_override IS NULL OR permission_mode_override IN ('auto', 'manual'));

COMMENT ON COLUMN pendingbot.crew_sessions.permission_mode_override IS
  'spec v2 §10: session 级覆盖。null = 继承 crew 默认(temporary_group_meta.permission_mode)。';

-- ────────────────────────────────────────────────────────────────────
-- 3) Extend message_kind constraints to include 'permission_request'
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.crew_announcements
  DROP CONSTRAINT IF EXISTS crew_announcements_message_kind_check;
ALTER TABLE pendingbot.crew_announcements
  ADD CONSTRAINT crew_announcements_message_kind_check CHECK (message_kind IN (
    'announcement',
    'instruction',
    'status',
    'question',
    'handoff',
    'result',
    'blocker',
    'permission_request'
  ));

ALTER TABLE pendingbot.session_mailbox_items
  DROP CONSTRAINT IF EXISTS session_mailbox_items_message_kind_check;
ALTER TABLE pendingbot.session_mailbox_items
  ADD CONSTRAINT session_mailbox_items_message_kind_check CHECK (message_kind IN (
    'announcement',
    'instruction',
    'status',
    'question',
    'handoff',
    'result',
    'blocker',
    'permission_request'
  ));

-- ────────────────────────────────────────────────────────────────────
-- 4) RPC create_permission_request
--
-- Called by service-role only (request_permission bot tool, which runs
-- in the edge worker with the SUPABASE_SERVICE_ROLE_KEY client).
--
-- Behaviour:
--   * Inserts a row into pendingbot.permission_requests
--     (status='pending', risk_level defaulting to 'medium' if not given).
--   * Inserts a parallel row into pendingbot.crew_announcements with
--     message_kind='permission_request', sender_kind='session',
--     board_visible=true, payload containing the new request id +
--     action + detail (so the iOS/Mac card can render straight from
--     the announcement row).
--   * Returns the new permission_requests.id.
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.create_permission_request(uuid, text, jsonb, text);

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
  -- Service-role only: this RPC is called by the edge worker's bot tool
  -- handler. Authenticated users can't construct permission requests
  -- directly; they decide them via decide_permission_request.
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

  -- Mirror onto the crew whiteboard as a special card.
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

  -- Also drop a parallel messages.log row in the crew conversation so
  -- the iOS PendingBot timeline (when it renders crew conversations in
  -- T4.6) and any other messages-table consumer can pick up the card
  -- without learning crew_announcements semantics. log_kind matches the
  -- one iOS dispatches on in ConversationView+Loading.swift.
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

ALTER FUNCTION pendingbot.create_permission_request(uuid, text, jsonb, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_permission_request(uuid, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_permission_request(uuid, text, jsonb, text) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 5) RPC decide_permission_request
--
-- Called by the edge worker after authenticating the caller (the route
-- handler resolves auth.uid() and passes it in as p_caller_user_id).
--
-- p_decision: 'approve' | 'reject' (maps to status 'approved' / 'denied')
--
-- Auth model:
--   * user_account responsible_subject — only that user can decide
--   * group_account responsible_subject — owner or admin can decide
--     (matching spec v2 §4.3: member 不能批 perm request)
--
-- Errors:
--   * P0002 — permission request not found
--   * 42501 — caller forbidden
--   * 22023 — invalid decision / already decided
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.decide_permission_request(uuid, text, uuid);

CREATE OR REPLACE FUNCTION pendingbot.decide_permission_request(
  p_id uuid,
  p_decision text,
  p_caller_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  req_row pendingbot.permission_requests%ROWTYPE;
  subject_row pendingbot.subjects%ROWTYPE;
  new_status text;
  current_caller uuid := auth.uid();
  effective_caller uuid;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'permission request id required' USING ERRCODE = '22023';
  END IF;

  -- Resolve effective caller:
  --   * If invoked by an authenticated user (auth.uid() set) — that user
  --     must match p_caller_user_id (defence against caller spoofing).
  --   * If invoked by service-role (auth.uid() null) — trust the passed
  --     p_caller_user_id; the edge worker is responsible for resolving
  --     the real session caller before invoking this RPC.
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
  IF p_decision NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'invalid decision' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO req_row
    FROM pendingbot.permission_requests
   WHERE id = p_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'permission request not found' USING ERRCODE = 'P0002';
  END IF;

  IF req_row.status <> 'pending' THEN
    RAISE EXCEPTION 'permission request already decided' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO subject_row
    FROM pendingbot.subjects
   WHERE id = req_row.responsible_subject_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'responsible subject missing' USING ERRCODE = 'P0002';
  END IF;

  -- Auth check
  IF subject_row.subject_type = 'user_account' THEN
    IF subject_row.user_id IS DISTINCT FROM effective_caller THEN
      RAISE EXCEPTION 'forbidden: only subject owner can decide' USING ERRCODE = '42501';
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

  new_status := CASE p_decision
    WHEN 'approve' THEN 'approved'
    WHEN 'reject' THEN 'denied'
  END;

  UPDATE pendingbot.permission_requests
     SET status = new_status,
         decided_at = now(),
         decided_by_user_id = effective_caller
   WHERE id = p_id;

  -- Update the announcement card payload so iOS/Mac re-render with the
  -- decided state. Match on permission_request_id in the payload —
  -- there should be exactly one such row per request, written by
  -- create_permission_request above.
  UPDATE pendingbot.crew_announcements
     SET payload = jsonb_set(
                     jsonb_set(payload, '{status}', to_jsonb(new_status), true),
                     '{decided_at}', to_jsonb(now()::text), true
                   )
   WHERE message_kind = 'permission_request'
     AND payload ->> 'permission_request_id' = p_id::text;

  -- Same patch onto the parallel messages.log row (so iOS timeline
  -- re-renders the card straight from log_payload).
  UPDATE pendingbot.messages
     SET log_payload = jsonb_set(
                         jsonb_set(log_payload, '{status}', to_jsonb(new_status), true),
                         '{decided_at}', to_jsonb(now()::text), true
                       )
   WHERE role = 'log'
     AND log_kind = 'permission_request'
     AND log_payload ->> 'permission_request_id' = p_id::text;
END $$;

ALTER FUNCTION pendingbot.decide_permission_request(uuid, text, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.decide_permission_request(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.decide_permission_request(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.decide_permission_request(uuid, text, uuid) TO service_role;

COMMIT;
