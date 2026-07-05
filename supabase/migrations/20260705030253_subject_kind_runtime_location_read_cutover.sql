-- 双写收口 Phase 1(可回滚段)— DB 侧读/写全部切到新列,旧列暂留。
--
-- 三组双写的现状(2026-07-05 live 核实):
--   1. subjects.subject_type(旧) ↔ subjects.kind(新, spec v2)
--      —— 触发器 subjects_sync_kind_trg 双向同步;live 3 行 0 漂移。
--   2. temporary_group_meta.runtime_kind(旧 'local'|'cloud') ↔
--      runtime_location(新 'local_host'|'peer_device'|'fly_machine',
--      写入时从 machine 派生)—— 无触发器,双写发生在两个 crew RPC 内;
--      live 0 行,0 漂移。※ 账本(tech-debt)把新旧方向记反了,以此为准。
--   3. fly_machine_id ↔ cloud_machine_id —— 已不存在:两列分别在
--      20260614123750 / 20260616024230 被 machine_id(→ pendingbot.machine)
--      取代并 drop。本次无事可做。
--
-- 本迁移把所有仍引用旧列的 DB 对象(13 个函数 + 2 个视图 + 5 条 RLS 策略 +
-- 2 个部分唯一索引)改写为引用新列。旧列本身与同步触发器留到 Phase 2
-- (drop 段)再清,期间任意写入仍由触发器保证 subject_type = kind。
--
-- 引用清单来源:live pg_proc.prosrc / pg_policy / pg_indexes /
-- information_schema.views 全量 grep,非账本记载。

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- 1. subjects 部分唯一索引:谓词 subject_type → kind
--    (ensure_user_subject / ensure_group_subject_for_conversation 的
--    ON CONFLICT 仲裁索引,谓词必须与函数里的 WHERE 子句一致,故与
--    下方函数改写同一事务原子切换。3 行小表,重建瞬时。)
-- ─────────────────────────────────────────────────────────────────────
DROP INDEX IF EXISTS pendingbot.subjects_user_account_uniq;
CREATE UNIQUE INDEX subjects_user_account_uniq
  ON pendingbot.subjects(user_id)
  WHERE kind = 'user_account';

DROP INDEX IF EXISTS pendingbot.subjects_group_account_uniq;
CREATE UNIQUE INDEX subjects_group_account_uniq
  ON pendingbot.subjects(group_conversation_id)
  WHERE kind = 'group_account';

-- ─────────────────────────────────────────────────────────────────────
-- 2. RLS 策略:subject_type → kind
-- ─────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS subjects_self_read ON pendingbot.subjects;
CREATE POLICY subjects_self_read ON pendingbot.subjects
  FOR SELECT TO authenticated
  USING (
    (kind = 'user_account' AND user_id = auth.uid())
    OR pendingbot.subject_has_user_access(id, auth.uid())
  );

DROP POLICY IF EXISTS machine_self_read ON pendingbot.machine;
CREATE POLICY machine_self_read ON pendingbot.machine
  FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM pendingbot.subjects s
     WHERE s.id = machine.subject_id
       AND s.kind = 'user_account'
       AND s.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS machine_self_insert ON pendingbot.machine;
CREATE POLICY machine_self_insert ON pendingbot.machine
  FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM pendingbot.subjects s
     WHERE s.id = machine.subject_id
       AND s.kind = 'user_account'
       AND s.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS machine_self_update ON pendingbot.machine;
CREATE POLICY machine_self_update ON pendingbot.machine
  FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM pendingbot.subjects s
     WHERE s.id = machine.subject_id
       AND s.kind = 'user_account'
       AND s.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM pendingbot.subjects s
     WHERE s.id = machine.subject_id
       AND s.kind = 'user_account'
       AND s.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS machine_self_delete ON pendingbot.machine;
CREATE POLICY machine_self_delete ON pendingbot.machine
  FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM pendingbot.subjects s
     WHERE s.id = machine.subject_id
       AND s.kind = 'user_account'
       AND s.user_id = auth.uid()
  ));

-- ─────────────────────────────────────────────────────────────────────
-- 3. 视图
-- ─────────────────────────────────────────────────────────────────────

-- 3a. bi_subjects:输出列形状不变(BI 面板仍按 subject_type 列名 JOIN),
--     但 subject_type 改为 kind 的别名,不再依赖旧列。
CREATE OR REPLACE VIEW pendingbot.bi_subjects AS
SELECT
  id,
  user_id,
  display_name,
  kind AS subject_type,
  kind
FROM pendingbot.subjects;

-- 3b. crew_link_summaries:runtime_kind 列改为 runtime_location(列名变更,
--     CREATE OR REPLACE 做不到,DROP 重建)。edge crew.ts 唯一消费方已同步
--     改读 runtime_location。重建后按 20260527165053 的加固姿势恢复:
--     security_invoker + 收走 anon/authenticated 直读。
DROP VIEW IF EXISTS pendingbot.crew_link_summaries;
CREATE VIEW pendingbot.crew_link_summaries AS
  SELECT
    cpl.child_crew_id AS current_crew_id,
    cpl.parent_crew_id AS linked_crew_id,
    'parent'::text AS direction,
    COALESCE(parent_meta.title, parent_conv.title, 'Crew') AS title,
    parent_meta.status,
    parent_meta.runtime_location,
    parent_meta.captain_bot_id,
    parent_member.id AS captain_member_id,
    cpl.created_at
  FROM pendingbot.crew_parent_links cpl
  JOIN pendingbot.temporary_group_meta parent_meta
    ON parent_meta.conversation_id = cpl.parent_crew_id
   AND parent_meta.temporary_kind = 'crew'
  JOIN pendingbot.conversations parent_conv
    ON parent_conv.id = cpl.parent_crew_id
  LEFT JOIN pendingbot.temporary_group_members parent_member
    ON parent_member.conversation_id = cpl.parent_crew_id
   AND parent_member.member_kind = 'captain'
   AND parent_member.represents_crew_id = cpl.child_crew_id
   AND parent_member.status = 'active'
  UNION ALL
  SELECT
    cpl.parent_crew_id AS current_crew_id,
    cpl.child_crew_id AS linked_crew_id,
    'child'::text AS direction,
    COALESCE(child_meta.title, child_conv.title, 'Crew') AS title,
    child_meta.status,
    child_meta.runtime_location,
    child_meta.captain_bot_id,
    child_member.id AS captain_member_id,
    cpl.created_at
  FROM pendingbot.crew_parent_links cpl
  JOIN pendingbot.temporary_group_meta child_meta
    ON child_meta.conversation_id = cpl.child_crew_id
   AND child_meta.temporary_kind = 'crew'
  JOIN pendingbot.conversations child_conv
    ON child_conv.id = cpl.child_crew_id
  LEFT JOIN pendingbot.temporary_group_members child_member
    ON child_member.conversation_id = cpl.parent_crew_id
   AND child_member.member_kind = 'captain'
   AND child_member.represents_crew_id = cpl.child_crew_id
   AND child_member.status = 'active';

ALTER VIEW pendingbot.crew_link_summaries SET (security_invoker = on);
REVOKE ALL ON pendingbot.crew_link_summaries FROM anon;
REVOKE ALL ON pendingbot.crew_link_summaries FROM authenticated;
GRANT SELECT ON pendingbot.crew_link_summaries TO service_role;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_ro') THEN
    GRANT SELECT ON pendingbot.crew_link_summaries TO bi_ro;
  END IF;
END
$$;

-- ─────────────────────────────────────────────────────────────────────
-- 4. 函数:subject_type → kind(体改写,签名/OWNER/GRANT 不动)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot._crew_caller_can_act_for_subject(p_subject_id uuid, p_caller uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pendingbot', 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.subjects s
     WHERE s.id = p_subject_id
       AND s.status = 'active'
       AND (
         (s.kind = 'user_account' AND s.user_id = p_caller)
         OR EXISTS (
           SELECT 1
             FROM pendingbot.group_subject_members gsm
            WHERE gsm.subject_id = s.id
              AND gsm.user_id = p_caller
              AND gsm.role IN ('owner', 'admin')
         )
       )
  )
$function$;

CREATE OR REPLACE FUNCTION pendingbot.subject_has_user_access(p_subject_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.subjects s
        WHERE s.id = p_subject_id
          AND s.status = 'active'
          AND (
            (s.kind = 'user_account' AND s.user_id = p_user_id)
            OR EXISTS (
              SELECT 1
                FROM pendingbot.group_subject_members gsm
               WHERE gsm.subject_id = s.id
                 AND gsm.user_id = p_user_id
            )
          )
     )
$function$;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_create_crew(p_subject_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.subjects s
        WHERE s.id = p_subject_id
          AND s.status = 'active'
          AND (
            (s.kind = 'user_account' AND s.user_id = p_user_id)
            OR EXISTS (
              SELECT 1
                FROM pendingbot.group_subject_members gsm
               WHERE gsm.subject_id = s.id
                 AND gsm.user_id = p_user_id
                 AND gsm.can_create_crew = true
            )
          )
     )
$function$;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_manage_runners(p_subject_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.subjects s
        WHERE s.id = p_subject_id
          AND s.status = 'active'
          AND (
            (s.kind = 'user_account' AND s.user_id = p_user_id)
            OR EXISTS (
              SELECT 1
                FROM pendingbot.group_subject_members gsm
               WHERE gsm.subject_id = s.id
                 AND gsm.user_id = p_user_id
                 AND gsm.can_manage_runners = true
            )
          )
     )
$function$;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_authorize_device_grant(p_subject_id uuid, p_user_id uuid, p_grant_kind text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.subjects s
        WHERE s.id = p_subject_id
          AND s.status = 'active'
          AND (
            (s.kind = 'user_account' AND s.user_id = p_user_id)
            OR (
              s.kind = 'group_account'
              AND (
                (
                  p_grant_kind = 'pendingcrew_runner'
                  AND EXISTS (
                    SELECT 1
                      FROM pendingbot.group_subject_members gsm
                     WHERE gsm.subject_id = s.id
                       AND gsm.user_id = p_user_id
                       AND gsm.can_manage_runners = true
                  )
                )
                OR (
                  p_grant_kind = 'pendingcrew_control'
                  AND EXISTS (
                    SELECT 1
                      FROM pendingbot.group_subject_members gsm
                     WHERE gsm.subject_id = s.id
                       AND gsm.user_id = p_user_id
                       AND (gsm.role IN ('owner', 'admin') OR gsm.can_create_crew = true)
                  )
                )
                OR (
                  p_grant_kind = 'pendingbot_client'
                  AND EXISTS (
                    SELECT 1
                      FROM pendingbot.group_subject_members gsm
                     WHERE gsm.subject_id = s.id
                       AND gsm.user_id = p_user_id
                       AND gsm.role IN ('owner', 'admin')
                  )
                )
              )
            )
          )
     )
$function$;

-- ensure_user_subject / ensure_group_subject_for_conversation:
-- INSERT 列与 ON CONFLICT 仲裁谓词一并切到 kind(与第 1 节索引重建配套)。
CREATE OR REPLACE FUNCTION pendingbot.ensure_user_subject(p_user_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
DECLARE
  v_subject_id uuid;
  v_display_name text;
BEGIN
  SELECT COALESCE(NULLIF(display_name, ''), email, '你')
    INTO v_display_name
    FROM pendingbot.users
   WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.subjects(kind, user_id, display_name)
  VALUES ('user_account', p_user_id, v_display_name)
  ON CONFLICT (user_id) WHERE kind = 'user_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  RETURN v_subject_id;
END $function$;

CREATE OR REPLACE FUNCTION pendingbot.ensure_group_subject_for_conversation(p_conversation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
DECLARE
  v_subject_id uuid;
  v_title text;
  v_creator uuid;
BEGIN
  SELECT
    COALESCE(NULLIF(cgm.title, ''), NULLIF(c.title, ''), '群账号'),
    cgm.created_by
    INTO v_title, v_creator
    FROM pendingbot.conversations c
    LEFT JOIN pendingbot.conversation_group_meta cgm
      ON cgm.conversation_id = c.id
   WHERE c.id = p_conversation_id
     AND c.conversation_type = 'group';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group conversation not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.subjects(kind, group_conversation_id, display_name)
  VALUES ('group_account', p_conversation_id, v_title)
  ON CONFLICT (group_conversation_id) WHERE kind = 'group_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  IF v_creator IS NOT NULL THEN
    INSERT INTO pendingbot.group_subject_members(
      subject_id,
      user_id,
      role,
      can_manage_wallet,
      can_manage_runners,
      can_create_crew
    ) VALUES (
      v_subject_id,
      v_creator,
      'owner',
      true,
      true,
      true
    )
    ON CONFLICT (subject_id, user_id) DO UPDATE SET
      role = CASE
        WHEN pendingbot.group_subject_members.role = 'owner' THEN 'owner'
        ELSE EXCLUDED.role
      END,
      can_manage_wallet = pendingbot.group_subject_members.can_manage_wallet OR EXCLUDED.can_manage_wallet,
      can_manage_runners = pendingbot.group_subject_members.can_manage_runners OR EXCLUDED.can_manage_runners,
      can_create_crew = pendingbot.group_subject_members.can_create_crew OR EXCLUDED.can_create_crew;
  END IF;

  RETURN v_subject_id;
END $function$;

-- grp_create_group_subject:去掉 kind/subject_type 双写,只写 kind
-- (过渡期 subject_type 由 subjects_sync_kind_trg 回填)。
CREATE OR REPLACE FUNCTION pendingbot.grp_create_group_subject(p_display_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_subject_id uuid;
  v_clean_name text;
BEGIN
  v_clean_name := COALESCE(NULLIF(trim(p_display_name), ''), '群账号');

  INSERT INTO pendingbot.subjects(kind, display_name, created_by)
  VALUES ('group_account', v_clean_name, v_caller)
  RETURNING id INTO v_subject_id;

  INSERT INTO pendingbot.group_subject_members(
    subject_id, user_id, role,
    granted_by, granted_at,
    can_manage_wallet, can_manage_runners, can_create_crew
  ) VALUES (
    v_subject_id, v_caller, 'owner',
    v_caller, now(),
    true, true, true
  );

  RETURN v_subject_id;
END $function$;

CREATE OR REPLACE FUNCTION pendingbot.answer_interaction_request(p_id uuid, p_reply_text text, p_caller_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
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
  IF subject_row.kind = 'user_account' THEN
    IF subject_row.user_id IS DISTINCT FROM effective_caller THEN
      RAISE EXCEPTION 'forbidden: only subject owner can answer' USING ERRCODE = '42501';
    END IF;
  ELSIF subject_row.kind = 'group_account' THEN
    IF NOT pendingbot.subject_user_has_role(
      subject_row.id,
      effective_caller,
      ARRAY['owner', 'admin']
    ) THEN
      RAISE EXCEPTION 'forbidden: owner or admin required' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'unsupported subject kind' USING ERRCODE = '22023';
  END IF;

  UPDATE pendingbot.permission_requests
     SET status = 'answered',
         reply_text = reply_clean,
         decided_at = now(),
         decided_by_user_id = effective_caller
   WHERE id = p_id;
END $function$;

CREATE OR REPLACE FUNCTION pendingbot.decide_permission_request(p_id uuid, p_decision text, p_caller_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
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
  IF subject_row.kind = 'user_account' THEN
    IF subject_row.user_id IS DISTINCT FROM effective_caller THEN
      RAISE EXCEPTION 'forbidden: only subject owner can decide' USING ERRCODE = '42501';
    END IF;
  ELSIF subject_row.kind = 'group_account' THEN
    IF NOT pendingbot.subject_user_has_role(
      subject_row.id,
      effective_caller,
      ARRAY['owner', 'admin']
    ) THEN
      RAISE EXCEPTION 'forbidden: owner or admin required' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'unsupported subject kind' USING ERRCODE = '22023';
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
END $function$;

-- crew_add_member_for_subject:human 分支的 subject 成员判定 subject_type → kind。
-- 体量大,除该处外逐字保留 live 定义。
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

-- ─────────────────────────────────────────────────────────────────────
-- 5. crew RPC:不再写 runtime_kind(列 Phase 2 drop;期间靠列默认值 'local')
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.create_crew_with_captain(p_responsible_subject_id uuid, p_title text, p_working_directory text DEFAULT NULL::text, p_captain_source text DEFAULT 'system_generated'::text, p_captain_bot_id uuid DEFAULT NULL::uuid, p_captain_template_name text DEFAULT NULL::text, p_actor_user_id uuid DEFAULT NULL::uuid, p_machine_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
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
END $function$;

-- create_child_crew_inheriting_responsibility_for_actor:
-- 旧版把 parent 的 runtime_kind 抄给 child、runtime_location 落默认
-- 'local_host'(fly 父 + local 子的不一致镜像)。改为继承 parent 的
-- runtime_location + machine_id(两者语义上成对,派生规则一致)。
CREATE OR REPLACE FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_actor(p_parent_crew_conversation_id uuid, p_actor_user_id uuid, p_title text DEFAULT ''::text, p_created_by_kind text DEFAULT 'human'::text, p_created_by_bot_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
DECLARE
  parent_meta pendingbot.temporary_group_meta%ROWTYPE;
  child_id uuid;
  title_text text;
  member_id uuid;
BEGIN
  SELECT *
    INTO parent_meta
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_parent_crew_conversation_id
     AND temporary_kind = 'crew'
     AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'parent crew not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'actor required' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.user_can_control_crew_by_responsibility(p_parent_crew_conversation_id, p_actor_user_id) THEN
    RAISE EXCEPTION 'forbidden: cannot create child crew for parent responsibility' USING ERRCODE = '42501';
  END IF;

  title_text := NULLIF(trim(COALESCE(p_title, '')), '');
  IF title_text IS NULL THEN
    title_text := '机组';
  END IF;

  INSERT INTO pendingbot.conversations(
    conversation_type,
    feature,
    user_id,
    bot_id,
    title,
    metadata
  ) VALUES (
    'crew',
    'message',
    p_actor_user_id,
    NULL,
    title_text,
    jsonb_build_object('surface', 'crew', 'parentCrewId', p_parent_crew_conversation_id)
  )
  RETURNING id INTO child_id;

  INSERT INTO pendingbot.temporary_group_meta(
    conversation_id,
    temporary_kind,
    responsible_subject_id,
    initiator_type,
    initiator_user_id,
    source_conversation_id,
    parent_temporary_group_id,
    root_temporary_group_id,
    title,
    runtime_location,
    machine_id,
    responsibility_mode
  ) VALUES (
    child_id,
    'crew',
    parent_meta.responsible_subject_id,
    'human',
    p_actor_user_id,
    p_parent_crew_conversation_id,
    p_parent_crew_conversation_id,
    COALESCE(parent_meta.root_temporary_group_id, p_parent_crew_conversation_id),
    title_text,
    parent_meta.runtime_location,
    parent_meta.machine_id,
    'inherit'
  );

  INSERT INTO pendingbot.crew_parent_links(
    parent_crew_id,
    child_crew_id,
    created_by_kind,
    created_by_user_id,
    created_by_bot_id,
    responsibility_mode
  ) VALUES (
    p_parent_crew_conversation_id,
    child_id,
    p_created_by_kind,
    CASE WHEN p_created_by_kind = 'human' THEN p_actor_user_id ELSE NULL END,
    CASE WHEN p_created_by_kind = 'captain' THEN p_created_by_bot_id ELSE NULL END,
    'inherit'
  );

  INSERT INTO pendingbot.temporary_group_members(
    conversation_id,
    member_kind,
    user_id,
    display_name,
    role,
    capabilities
  )
  SELECT
    child_id,
    'human',
    p_actor_user_id,
    COALESCE(NULLIF(u.display_name, ''), u.email, '你'),
    'owner',
    jsonb_build_object('can_create_session', true, 'can_manage_crew', true)
    FROM pendingbot.users u
   WHERE u.id = p_actor_user_id
  RETURNING id INTO member_id;

  IF member_id IS NULL THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.conversation_participants(
    conversation_id,
    participant_type,
    participant_id,
    role
  ) VALUES (
    child_id,
    'user',
    p_actor_user_id,
    'owner'
  )
  ON CONFLICT DO NOTHING;

  RETURN child_id;
END $function$;

COMMIT;
