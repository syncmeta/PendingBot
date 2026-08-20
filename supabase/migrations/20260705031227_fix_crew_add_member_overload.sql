-- 修正 20260705030253 的失手:该迁移最初以错误的参数顺序
-- (p_crew_conversation_id 在首位、p_actor_user_id 带默认值)
-- CREATE OR REPLACE crew_add_member_for_subject,结果没有替换 live 函数
-- (identity 不同),而是新建了一个重载 —— PostgREST 命名参数调用会撞
-- "function is not unique"。
--
-- 本迁移:
--   1. DROP 误建的重载(参数顺序 uuid,text,uuid,uuid,uuid 那个);
--   2. 以 live 原始签名(p_actor_user_id uuid, p_crew_conversation_id uuid,
--      p_member_kind text, p_bot_id uuid DEFAULT NULL, p_user_id uuid
--      DEFAULT NULL)重放 subject_type → kind 的体改写。
-- 20260705030253 文件本身已同步改正;对全新数据库重放时本迁移的 DROP
-- 是 no-op,CREATE OR REPLACE 幂等。

BEGIN;

DROP FUNCTION IF EXISTS pendingbot.crew_add_member_for_subject(p_crew_conversation_id uuid, p_member_kind text, p_bot_id uuid, p_user_id uuid, p_actor_user_id uuid);

CREATE OR REPLACE FUNCTION pendingbot.crew_add_member_for_subject(p_actor_user_id uuid, p_crew_conversation_id uuid, p_member_kind text, p_bot_id uuid DEFAULT NULL::uuid, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
DECLARE
  v_caller        uuid := COALESCE(auth.uid(), p_actor_user_id);
  v_subject_id    uuid;
  v_existing      pendingbot.temporary_group_members%ROWTYPE;
  v_member        pendingbot.temporary_group_members%ROWTYPE;
  v_display_name  text;
  v_bot_visibility text;
  v_bot_creator   uuid;
  v_bot_active    boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;

  -- 1) crew 存在性
  SELECT responsible_subject_id
    INTO v_subject_id
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_crew_conversation_id
     AND temporary_kind = 'crew';
  IF v_subject_id IS NULL THEN
    RAISE EXCEPTION 'crew not found' USING ERRCODE = 'P0002';
  END IF;

  -- 2) actor 能为 responsible_subject 出面
  IF NOT pendingbot._crew_caller_can_act_for_subject(v_subject_id, v_caller) THEN
    RAISE EXCEPTION 'forbidden: caller cannot act for responsible subject' USING ERRCODE = '42501';
  END IF;

  -- 3) 按 kind 校验目标 + 解析显示名
  IF p_member_kind = 'registered_bot' THEN
    IF p_bot_id IS NULL THEN
      RAISE EXCEPTION 'p_bot_id required for registered_bot' USING ERRCODE = '22023';
    END IF;

    SELECT visibility, creator_id, is_active
      INTO v_bot_visibility, v_bot_creator, v_bot_active
      FROM pendingbot.bots
     WHERE id = p_bot_id;
    IF v_bot_visibility IS NULL THEN
      RAISE EXCEPTION 'bot not found' USING ERRCODE = 'P0002';
    END IF;
    IF NOT COALESCE(v_bot_active, false) THEN
      RAISE EXCEPTION 'bot is inactive' USING ERRCODE = '22023';
    END IF;
    -- 自己的 bot 直通;否则须非 private 且 actor 已加为联系人
    IF v_bot_creator IS DISTINCT FROM v_caller THEN
      IF v_bot_visibility = 'private' THEN
        RAISE EXCEPTION 'forbidden: private bots cannot be added by non-owner' USING ERRCODE = '42501';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM pendingbot.user_bot_contacts ubc
         WHERE ubc.user_id = v_caller AND ubc.bot_id = p_bot_id
      ) THEN
        RAISE EXCEPTION 'forbidden: bot not visible to caller' USING ERRCODE = '42501';
      END IF;
    END IF;

    v_display_name := pendingbot._crew_bot_display_name(p_bot_id);

    -- 幂等:已是 active 成员则原样返回
    SELECT * INTO v_existing
      FROM pendingbot.temporary_group_members
     WHERE conversation_id = p_crew_conversation_id
       AND member_kind = 'registered_bot'
       AND bot_id = p_bot_id
       AND status = 'active'
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'id', v_existing.id,
        'member_kind', v_existing.member_kind,
        'bot_id', v_existing.bot_id,
        'user_id', v_existing.user_id,
        'display_name', v_existing.display_name,
        'role', v_existing.role,
        'status', v_existing.status,
        'created_at', v_existing.created_at,
        'already_member', true
      );
    END IF;

    INSERT INTO pendingbot.temporary_group_members(
      conversation_id, member_kind, bot_id, display_name, role
    ) VALUES (
      p_crew_conversation_id, 'registered_bot', p_bot_id, v_display_name, 'member'
    )
    RETURNING * INTO v_member;

    INSERT INTO pendingbot.conversation_participants(
      conversation_id, participant_type, participant_id, role
    ) VALUES (p_crew_conversation_id, 'bot', p_bot_id, 'member')
    ON CONFLICT DO NOTHING;

  ELSIF p_member_kind = 'human' THEN
    IF p_user_id IS NULL THEN
      RAISE EXCEPTION 'p_user_id required for human' USING ERRCODE = '22023';
    END IF;

    -- 目标须是 actor 好友,或 subject 成员(user_account 本人 / group 成员)
    IF NOT (
      EXISTS (
        SELECT 1 FROM pendingbot.user_contacts uc
         WHERE uc.user_id = v_caller AND uc.contact_user_id = p_user_id
      )
      OR EXISTS (
        SELECT 1 FROM pendingbot.subjects s
         WHERE s.id = v_subject_id
           AND s.kind = 'user_account'
           AND s.user_id = p_user_id
      )
      OR EXISTS (
        SELECT 1 FROM pendingbot.group_subject_members gsm
         WHERE gsm.subject_id = v_subject_id AND gsm.user_id = p_user_id
      )
    ) THEN
      RAISE EXCEPTION 'forbidden: target user is not a friend of caller nor a subject member' USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(NULLIF(display_name, ''), email, '成员')
      INTO v_display_name
      FROM pendingbot.users
     WHERE id = p_user_id;
    IF v_display_name IS NULL THEN
      RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
    END IF;

    SELECT * INTO v_existing
      FROM pendingbot.temporary_group_members
     WHERE conversation_id = p_crew_conversation_id
       AND member_kind = 'human'
       AND user_id = p_user_id
       AND status = 'active'
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'id', v_existing.id,
        'member_kind', v_existing.member_kind,
        'bot_id', v_existing.bot_id,
        'user_id', v_existing.user_id,
        'display_name', v_existing.display_name,
        'role', v_existing.role,
        'status', v_existing.status,
        'created_at', v_existing.created_at,
        'already_member', true
      );
    END IF;

    INSERT INTO pendingbot.temporary_group_members(
      conversation_id, member_kind, user_id, display_name, role
    ) VALUES (
      p_crew_conversation_id, 'human', p_user_id, v_display_name, 'member'
    )
    RETURNING * INTO v_member;

    INSERT INTO pendingbot.conversation_participants(
      conversation_id, participant_type, participant_id, role
    ) VALUES (p_crew_conversation_id, 'user', p_user_id, 'member')
    ON CONFLICT DO NOTHING;

  ELSE
    RAISE EXCEPTION 'invalid member_kind (expected registered_bot|human)' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'id', v_member.id,
    'member_kind', v_member.member_kind,
    'bot_id', v_member.bot_id,
    'user_id', v_member.user_id,
    'display_name', v_member.display_name,
    'role', v_member.role,
    'status', v_member.status,
    'created_at', v_member.created_at,
    'already_member', false
  );
END $function$;

COMMIT;
