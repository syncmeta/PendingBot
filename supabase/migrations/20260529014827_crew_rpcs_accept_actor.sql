-- Crew Phase-2 RPCs: accept an explicit actor user id for device-grant calls.
--
-- 背景:`/v1/crews`(Phase 2)整套 codex 写成 JWT-only —— router 上
-- `requireSession()`,handler 用 `userClient(jwt)` 让 RPC 里的 `auth.uid()`
-- 反映 caller。但 PendingCrew(crews 的主要消费端)用 device grant(`pdg_*`)
-- 鉴权,没有 supabase user JWT → `auth.uid()` 为 NULL → RPC 抛 28000 →
-- `POST /v1/crews` 等一律 401。
--
-- 修法沿用既有约定:legacy `/v1/crew`(单数)路由对 device grant 用
-- `open_crew_conv_for_subject(p_actor_user_id)` 这种"显式 actor"变体,
-- 经 service_role 调用。这里给 Phase-2 三个写 RPC 也加上
-- `p_actor_user_id uuid DEFAULT NULL`,并把
--   v_caller := auth.uid()
-- 换成
--   v_caller := COALESCE(auth.uid(), p_actor_user_id)
--
-- 安全性:`authenticated` 角色(走 userClient/JWT)调用时 auth.uid() 非空,
-- COALESCE 永远取 auth.uid(),传进来的 p_actor_user_id 被忽略 → 无法冒充。
-- 只有 service_role(无 JWT,auth.uid() 为 NULL)才会落到 p_actor_user_id,
-- 而 service key 只在 edge 内,且 edge 只填来自已验证 device grant 的
-- grantedByUserId。与 open_crew_conv_for_subject 的信任模型一致。
--
-- 三个 RPC 都要 DROP 旧签名再 CREATE(CREATE OR REPLACE 不能改参数列,
-- 否则会变成 overload 让 PostgREST 调用歧义)。read 侧的
-- can_view_temporary_group(p_conversation_id, p_user_id) 早就显式收 user_id,
-- GET 列表走 accessibleSubjectIds(显式 userId),都不依赖 auth.uid(),无需动。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) create_crew_with_captain
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text
);

CREATE OR REPLACE FUNCTION pendingbot.create_crew_with_captain(
  p_responsible_subject_id uuid,
  p_title                   text,
  p_runtime_location        text DEFAULT 'local_host',
  p_working_directory       text DEFAULT NULL,
  p_tag                     text DEFAULT NULL,
  p_captain_source          text DEFAULT 'system_generated',
  p_captain_bot_id          uuid DEFAULT NULL,
  p_captain_template_name   text DEFAULT NULL,
  p_peer_device_id          uuid DEFAULT NULL,
  p_fly_machine_id          text DEFAULT NULL,
  p_actor_user_id           uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller        uuid := COALESCE(auth.uid(), p_actor_user_id);
  v_conv_id       uuid;
  v_captain_id    uuid;
  v_clean_title   text;
  v_captain_name  text;
  v_caller_display text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;

  -- 1) 权限:caller 能为 responsible_subject 出面
  IF NOT pendingbot._crew_caller_can_act_for_subject(p_responsible_subject_id, v_caller) THEN
    RAISE EXCEPTION 'forbidden: caller cannot act for responsible subject' USING ERRCODE = '42501';
  END IF;

  -- 2) 校验枚举/取值
  IF p_captain_source NOT IN ('reuse_bot', 'system_generated') THEN
    RAISE EXCEPTION 'invalid captain_source (expected reuse_bot|system_generated)' USING ERRCODE = '22023';
  END IF;

  IF p_runtime_location NOT IN ('local_host', 'peer_device', 'fly_machine') THEN
    RAISE EXCEPTION 'invalid runtime_location' USING ERRCODE = '22023';
  END IF;

  IF p_runtime_location = 'peer_device' AND p_peer_device_id IS NULL THEN
    RAISE EXCEPTION 'peer_device_id required when runtime_location=peer_device' USING ERRCODE = '22023';
  END IF;
  IF p_runtime_location = 'fly_machine' AND p_fly_machine_id IS NULL THEN
    RAISE EXCEPTION 'fly_machine_id required when runtime_location=fly_machine' USING ERRCODE = '22023';
  END IF;
  IF p_runtime_location = 'local_host' AND (p_peer_device_id IS NOT NULL OR p_fly_machine_id IS NOT NULL) THEN
    RAISE EXCEPTION 'peer_device_id/fly_machine_id must be NULL for local_host' USING ERRCODE = '22023';
  END IF;

  v_clean_title := NULLIF(trim(COALESCE(p_title, '')), '');
  IF v_clean_title IS NULL THEN
    v_clean_title := '机组';
  END IF;

  -- 3) 解析 captain
  IF p_captain_source = 'reuse_bot' THEN
    IF p_captain_bot_id IS NULL THEN
      RAISE EXCEPTION 'p_captain_bot_id required for reuse_bot' USING ERRCODE = '22023';
    END IF;
    IF NOT pendingbot._crew_caller_owns_bot(p_captain_bot_id, v_caller) THEN
      RAISE EXCEPTION 'forbidden: caller does not own captain bot' USING ERRCODE = '42501';
    END IF;
    v_captain_id := p_captain_bot_id;
    v_captain_name := pendingbot._crew_bot_display_name(v_captain_id);
  ELSE
    -- system_generated:内部 insert 新 bot
    v_captain_name := NULLIF(trim(COALESCE(p_captain_template_name, '')), '');
    IF v_captain_name IS NULL THEN
      v_captain_name := v_clean_title || ' 机长';
    END IF;

    INSERT INTO pendingbot.bots(
      slug, display_name, model_id, creator_id, visibility, config
    ) VALUES (
      'captain-' || replace(pendingbot.uuidv7()::text, '-', ''),
      v_captain_name,
      'openrouter/auto',
      v_caller,
      'private',
      jsonb_build_object('role', 'captain', 'auto_generated', true)
    )
    RETURNING id INTO v_captain_id;
  END IF;

  -- 4) 创建 conversation
  INSERT INTO pendingbot.conversations(
    conversation_type, feature, user_id, bot_id, title, metadata
  ) VALUES (
    'crew',
    'message',
    v_caller,
    NULL,
    v_clean_title,
    jsonb_build_object('surface', 'crew', 'captainSource', p_captain_source)
  )
  RETURNING id INTO v_conv_id;

  -- 5) temporary_group_meta(crew 行) — 同时写新老 runtime 字段
  INSERT INTO pendingbot.temporary_group_meta(
    conversation_id,
    temporary_kind,
    responsible_subject_id,
    initiator_type,
    initiator_user_id,
    title,
    status,
    captain_bot_id,
    runtime_kind,
    runtime_location,
    tag,
    working_directory,
    peer_device_id,
    fly_machine_id,
    responsibility_mode
  ) VALUES (
    v_conv_id,
    'crew',
    p_responsible_subject_id,
    'human',
    v_caller,
    v_clean_title,
    'active',
    v_captain_id,
    CASE p_runtime_location WHEN 'fly_machine' THEN 'cloud' ELSE 'local' END,
    p_runtime_location,
    NULLIF(trim(COALESCE(p_tag, '')), ''),
    NULLIF(trim(COALESCE(p_working_directory, '')), ''),
    p_peer_device_id,
    p_fly_machine_id,
    'inherit'
  );

  -- 6) caller 显示名 + temporary_group_members(owner human)
  SELECT COALESCE(NULLIF(display_name, ''), email, '你')
    INTO v_caller_display
    FROM pendingbot.users
   WHERE id = v_caller;
  v_caller_display := COALESCE(v_caller_display, '你');

  INSERT INTO pendingbot.temporary_group_members(
    conversation_id, member_kind, user_id, display_name, role, capabilities
  ) VALUES (
    v_conv_id, 'human', v_caller, v_caller_display, 'owner',
    jsonb_build_object('can_create_session', true, 'can_manage_crew', true)
  );

  -- 7) captain → temporary_group_members
  --    check 约束要求 captain 行 represents_crew_id NOT NULL,我们用本 conv_id 自身代表"自己"。
  --    唯一索引 (conversation_id, represents_crew_id) WHERE captain&active 保证唯一性 OK。
  INSERT INTO pendingbot.temporary_group_members(
    conversation_id, member_kind, bot_id, represents_crew_id, display_name, role, capabilities
  ) VALUES (
    v_conv_id, 'captain', v_captain_id, v_conv_id,
    v_captain_name,
    'admin',
    jsonb_build_object('is_captain', true)
  );

  -- 8) conversation_participants(普通消息流权限)
  INSERT INTO pendingbot.conversation_participants(
    conversation_id, participant_type, participant_id, role
  ) VALUES (v_conv_id, 'user', v_caller, 'owner')
  ON CONFLICT DO NOTHING;

  INSERT INTO pendingbot.conversation_participants(
    conversation_id, participant_type, participant_id, role
  ) VALUES (v_conv_id, 'bot', v_captain_id, 'admin')
  ON CONFLICT DO NOTHING;

  RETURN v_conv_id;
END $$;

ALTER FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text, uuid
) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text, uuid
) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 2) crew_attach_as_child
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.crew_attach_as_child(uuid, uuid, integer);

CREATE OR REPLACE FUNCTION pendingbot.crew_attach_as_child(
  p_child uuid,
  p_parent uuid,
  p_child_keeps_bps integer,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller            uuid := COALESCE(auth.uid(), p_actor_user_id);
  v_child_subject_id  uuid;
  v_parent_share_bps  integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;

  IF p_child = p_parent THEN
    RAISE EXCEPTION 'child cannot equal parent' USING ERRCODE = '22023';
  END IF;

  IF p_child_keeps_bps < 1 OR p_child_keeps_bps > 9999 THEN
    RAISE EXCEPTION 'p_child_keeps_bps must be in 1..9999' USING ERRCODE = '22023';
  END IF;

  v_parent_share_bps := 10000 - p_child_keeps_bps;

  -- 取 child 的 responsible_subject
  SELECT responsible_subject_id
    INTO v_child_subject_id
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_child
     AND temporary_kind = 'crew'
     AND status IN ('active', 'closing', 'closed');

  IF v_child_subject_id IS NULL THEN
    RAISE EXCEPTION 'child crew not found' USING ERRCODE = 'P0002';
  END IF;

  -- 验证 parent 存在(否则 FK 也会挡)
  IF NOT EXISTS (
    SELECT 1 FROM pendingbot.temporary_group_meta
     WHERE conversation_id = p_parent
       AND temporary_kind = 'crew'
       AND status IN ('active', 'closing', 'closed')
  ) THEN
    RAISE EXCEPTION 'parent crew not found' USING ERRCODE = 'P0002';
  END IF;

  -- 权限:caller 能代表 child 的 responsible_subject(owner|admin)
  IF NOT pendingbot._crew_caller_can_act_for_subject(v_child_subject_id, v_caller) THEN
    RAISE EXCEPTION 'forbidden: caller cannot act for child responsible subject' USING ERRCODE = '42501';
  END IF;

  -- INSERT(cycle trigger 在 BEFORE 阶段挡环 → 抛 23514)
  -- UNIQUE(parent_crew_id, child_crew_id) 防重复;ON CONFLICT 我们让它直接报错给调用方
  INSERT INTO pendingbot.crew_parent_links(
    parent_crew_id,
    child_crew_id,
    link_kind,
    created_by_kind,
    created_by_user_id,
    responsibility_mode,
    child_share_bps
  ) VALUES (
    p_parent,
    p_child,
    'parent',
    'human',
    v_caller,
    'inherit',
    v_parent_share_bps
  );

  -- 触发 child 的 shares 重算(T2.4)
  PERFORM pendingbot.crew_recompute_shares(p_child);
END $$;

ALTER FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 3) crew_propose_share_change
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.crew_propose_share_change(uuid, jsonb, uuid[]);

CREATE OR REPLACE FUNCTION pendingbot.crew_propose_share_change(
  p_crew_id uuid,
  p_proposal_payload jsonb,
  p_requires_subject_approvals uuid[],
  p_actor_user_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := COALESCE(auth.uid(), p_actor_user_id);
  v_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;

  IF NOT pendingbot.can_view_temporary_group(p_crew_id, v_caller) THEN
    RAISE EXCEPTION 'forbidden: cannot view crew' USING ERRCODE = '42501';
  END IF;

  INSERT INTO pendingbot.crew_pending_share_changes(
    crew_id, proposed_by, proposal_payload, requires_subject_approvals
  ) VALUES (
    p_crew_id, v_caller, p_proposal_payload, p_requires_subject_approvals
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

ALTER FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[], uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[], uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[], uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[], uuid) TO service_role;

COMMIT;
