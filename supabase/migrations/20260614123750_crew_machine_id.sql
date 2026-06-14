-- Crew → machine FK. temporary_group_meta references a first-class machine (File 1)
-- via machine_id. runtime_location STAYS (≈6 consumers) but becomes derived at write
-- time from the chosen machine. We physically drop the low-coupling runtime pointers
-- peer_device_id / fly_machine_id (and their constraint/indexes cascade with the column).
set search_path = pendingbot, public;

alter table pendingbot.temporary_group_meta
  add column if not exists machine_id uuid references pendingbot.machine(id) on delete set null;
create index if not exists tgm_machine_idx on pendingbot.temporary_group_meta (machine_id);

alter table pendingbot.temporary_group_meta
  drop constraint if exists temporary_group_meta_runtime_target_chk;
alter table pendingbot.temporary_group_meta
  drop column if exists peer_device_id,
  drop column if exists fly_machine_id;

-- ────────────────────────────────────────────────────────────────────
-- Rewrite create_crew_with_captain
--   OLD: (uuid, text, text, text, text, text, uuid, text, uuid, text, uuid)
--        = p_responsible_subject_id, p_title, p_runtime_location, p_working_directory,
--          p_tag, p_captain_source, p_captain_bot_id, p_captain_template_name,
--          p_peer_device_id, p_fly_machine_id, p_actor_user_id
--   NEW: (uuid, text, text, text, uuid, text, uuid, uuid)
--        = p_responsible_subject_id, p_title, p_working_directory, p_captain_source,
--          p_captain_bot_id, p_captain_template_name, p_actor_user_id, p_machine_id
-- Removed p_runtime_location (now derived), p_tag (column dropped in File 3),
-- p_peer_device_id / p_fly_machine_id (columns dropped above). Added p_machine_id (last).
-- Signature changed → must DROP first (CREATE OR REPLACE cannot alter the arg list).
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.create_crew_with_captain(
  uuid, text, text, text, text, text, uuid, text, uuid, text, uuid
);

CREATE OR REPLACE FUNCTION pendingbot.create_crew_with_captain(
  p_responsible_subject_id uuid,
  p_title                   text,
  p_working_directory       text DEFAULT NULL,
  p_captain_source          text DEFAULT 'system_generated',
  p_captain_bot_id          uuid DEFAULT NULL,
  p_captain_template_name   text DEFAULT NULL,
  p_actor_user_id           uuid DEFAULT NULL,
  p_machine_id              uuid DEFAULT NULL
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
  v_runtime_location text;
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

  -- runtime_location 现在从所选 machine 派生(NULL machine → 本机)
  v_runtime_location := CASE
    WHEN p_machine_id IS NULL THEN 'local_host'
    WHEN (SELECT kind FROM pendingbot.machine WHERE id = p_machine_id) = 'fly' THEN 'fly_machine'
    ELSE 'local_host'
  END;

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

  -- 5) temporary_group_meta(crew 行) — runtime_location 派生自 machine,machine_id 直存
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
    working_directory,
    machine_id,
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
    CASE v_runtime_location WHEN 'fly_machine' THEN 'cloud' ELSE 'local' END,
    v_runtime_location,
    NULLIF(trim(COALESCE(p_working_directory, '')), ''),
    p_machine_id,
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
  uuid, text, text, text, uuid, text, uuid, uuid
) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, uuid, text, uuid, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, uuid, text, uuid, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_with_captain(
  uuid, text, text, text, uuid, text, uuid, uuid
) TO service_role;
