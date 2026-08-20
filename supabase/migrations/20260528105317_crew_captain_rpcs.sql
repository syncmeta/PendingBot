-- T2.2 — Captain + 三种来源 RPC(spec v2 §6.3)。
--
-- Schema 现状(已在 20260527090000_crew_dag_captain_responsibility.sql 落地):
--   * temporary_group_meta.captain_bot_id uuid REFERENCES bots(id) — ✅ 已加
--   * temporary_group_members.member_kind 已含 'captain' — ✅ 已加
--   * temporary_group_members.represents_crew_id uuid REFERENCES conversations(id) — ✅ 已加
--   * 唯一索引 temporary_group_members_active_captain_rep_uniq
--       ON (conversation_id, represents_crew_id) WHERE member_kind='captain' AND status='active' — ✅
--   * check 约束 temporary_group_members_kind_ref_chk 对 'captain' 行要求
--       bot_id NOT NULL AND user_id NULL AND represents_crew_id NOT NULL
--
-- 本迁移补:
--   1) helper bot_display_name(bot_id) 复用查 display_name
--   2) helper _crew_caller_can_act_for_subject — caller 在 subject 上 owner|admin
--   3) helper _crew_caller_owns_bot — caller 是 bot.creator_id
--   4) RPC create_crew_with_captain — 解析 captain_source ∈ {reuse_bot, system_generated}
--      在一个事务里建 conversation + temporary_group_meta + caller 成员行 + captain 成员行
--      (captain 成员行 represents_crew_id = 本 conv_id 自身,满足 check + 唯一索引)
--
-- 第三种 captain 来源 'spawned_by_captain' 走已存在的
-- create_child_crew_inheriting_responsibility_for_actor 链路(20260527090000)。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- helpers(必须先定义,RPC 后面会调用)
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot._crew_bot_display_name(p_bot_id uuid)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(NULLIF(display_name, ''), '机长')
    FROM pendingbot.bots
   WHERE id = p_bot_id
$$;

ALTER FUNCTION pendingbot._crew_bot_display_name(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._crew_bot_display_name(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pendingbot._crew_caller_owns_bot(p_bot_id uuid, p_caller uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.bots b
     WHERE b.id = p_bot_id
       AND b.creator_id = p_caller
  )
$$;

ALTER FUNCTION pendingbot._crew_caller_owns_bot(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._crew_caller_owns_bot(uuid, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pendingbot._crew_caller_can_act_for_subject(
  p_subject_id uuid,
  p_caller uuid
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.subjects s
     WHERE s.id = p_subject_id
       AND s.status = 'active'
       AND (
         (s.subject_type = 'user_account' AND s.user_id = p_caller)
         OR EXISTS (
           SELECT 1
             FROM pendingbot.group_subject_members gsm
            WHERE gsm.subject_id = s.id
              AND gsm.user_id = p_caller
              AND gsm.role IN ('owner', 'admin')
         )
       )
  )
$$;

ALTER FUNCTION pendingbot._crew_caller_can_act_for_subject(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._crew_caller_can_act_for_subject(uuid, uuid) FROM PUBLIC;

-- ────────────────────────────────────────────────────────────────────
-- create_crew_with_captain — 主 RPC
-- ────────────────────────────────────────────────────────────────────

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
  p_fly_machine_id          text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller        uuid := auth.uid();
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
  uuid, text, text, text, text, text, uuid, text, uuid, text
) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text
) TO service_role;

COMMIT;
