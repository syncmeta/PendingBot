-- T1.2 — 群账号权限矩阵 RPC 套件(spec v2 §4.3 α 简化版)。
--
-- 权限模型(三级 role + 固定默认权限,v1 不允许自定义):
--
-- | 操作                            | owner | admin | member |
-- |--------------------------------|-------|-------|--------|
-- | 加 member / 踢 member           | ✅    | ✅    | ❌      |
-- | 转让 ownership / 升降 admin     | ✅    | ❌    | ❌      |
-- | 群钱包充值                       | ✅    | ✅    | ✅      |
-- | (无提现 — 全员 ❌,不实现接口)   | ❌    | ❌    | ❌      |
--
-- 约束:
--   * 单 owner(v1 不做 multi-owner)
--   * 转让 ownership = 原 owner 自动降为 admin,目标必须已是 member/admin
--   * 不能踢 admin(只 owner 能通过先 demote 再 remove)
--   * 任何 user 都可以创建群账号,自动成为 owner
--
-- 全部 SECURITY DEFINER + 内部权限检查 + 入参 = auth.uid() 或 service_role bypass。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- helper: 调用者校验
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot._grp_require_caller()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_caller uuid;
BEGIN
  v_caller := auth.uid();
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;
  RETURN v_caller;
END $$;

ALTER FUNCTION pendingbot._grp_require_caller() OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._grp_require_caller() FROM PUBLIC;

CREATE OR REPLACE FUNCTION pendingbot._grp_require_group_subject(p_subject_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_kind text;
BEGIN
  SELECT kind INTO v_kind
    FROM pendingbot.subjects
   WHERE id = p_subject_id
     AND status = 'active';
  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'group subject not found or disabled' USING ERRCODE = 'P0002';
  END IF;
  IF v_kind <> 'group_account' THEN
    RAISE EXCEPTION 'subject is not a group account' USING ERRCODE = '22023';
  END IF;
END $$;

ALTER FUNCTION pendingbot._grp_require_group_subject(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._grp_require_group_subject(uuid) FROM PUBLIC;

-- 取 caller 在该群里的 role,找不到 = NULL
CREATE OR REPLACE FUNCTION pendingbot._grp_caller_role(p_subject_id uuid, p_caller uuid)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT role
    FROM pendingbot.group_subject_members
   WHERE subject_id = p_subject_id
     AND user_id = p_caller
$$;

ALTER FUNCTION pendingbot._grp_caller_role(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._grp_caller_role(uuid, uuid) FROM PUBLIC;

-- ────────────────────────────────────────────────────────────────────
-- grp_create_group_subject — 任意 user 可创建群账号
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_create_group_subject(
  p_display_name text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_subject_id uuid;
  v_clean_name text;
BEGIN
  v_clean_name := COALESCE(NULLIF(trim(p_display_name), ''), '群账号');

  INSERT INTO pendingbot.subjects(kind, subject_type, display_name, created_by)
  VALUES ('group_account', 'group_account', v_clean_name, v_caller)
  RETURNING id INTO v_subject_id;

  INSERT INTO pendingbot.subject_wallets(subject_id)
  VALUES (v_subject_id);

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
END $$;

ALTER FUNCTION pendingbot.grp_create_group_subject(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_create_group_subject(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_create_group_subject(text) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_create_group_subject(text) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- grp_add_member — owner/admin 可调
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_add_member(
  p_group_subject_id uuid,
  p_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_role text;
BEGIN
  PERFORM pendingbot._grp_require_group_subject(p_group_subject_id);

  v_role := pendingbot._grp_caller_role(p_group_subject_id, v_caller);
  IF v_role IS NULL OR v_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'forbidden: owner or admin required' USING ERRCODE = '42501';
  END IF;

  -- 目标 user 必须存在
  IF NOT EXISTS (SELECT 1 FROM pendingbot.users WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'target user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.group_subject_members(
    subject_id, user_id, role,
    granted_by, granted_at
  ) VALUES (
    p_group_subject_id, p_user_id, 'member',
    v_caller, now()
  )
  ON CONFLICT (subject_id, user_id) DO NOTHING;
END $$;

ALTER FUNCTION pendingbot.grp_add_member(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_add_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_add_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_add_member(uuid, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- grp_remove_member — owner/admin 可调,不能踢 admin/owner(admin 只 owner 能动)
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_remove_member(
  p_group_subject_id uuid,
  p_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_caller_role text;
  v_target_role text;
BEGIN
  PERFORM pendingbot._grp_require_group_subject(p_group_subject_id);

  v_caller_role := pendingbot._grp_caller_role(p_group_subject_id, v_caller);
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'forbidden: owner or admin required' USING ERRCODE = '42501';
  END IF;

  v_target_role := pendingbot._grp_caller_role(p_group_subject_id, p_user_id);
  IF v_target_role IS NULL THEN
    -- 已经不在,幂等成功
    RETURN;
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'cannot remove owner; transfer ownership first' USING ERRCODE = '42501';
  END IF;

  IF v_target_role = 'admin' AND v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'only owner can remove admin' USING ERRCODE = '42501';
  END IF;

  DELETE FROM pendingbot.group_subject_members
   WHERE subject_id = p_group_subject_id
     AND user_id = p_user_id;
END $$;

ALTER FUNCTION pendingbot.grp_remove_member(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_remove_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_remove_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_remove_member(uuid, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- grp_promote_to_admin — owner only
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_promote_to_admin(
  p_group_subject_id uuid,
  p_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_caller_role text;
  v_target_role text;
BEGIN
  PERFORM pendingbot._grp_require_group_subject(p_group_subject_id);

  v_caller_role := pendingbot._grp_caller_role(p_group_subject_id, v_caller);
  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'forbidden: owner required' USING ERRCODE = '42501';
  END IF;

  v_target_role := pendingbot._grp_caller_role(p_group_subject_id, p_user_id);
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'target is not a member' USING ERRCODE = 'P0002';
  END IF;
  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'target is owner' USING ERRCODE = '22023';
  END IF;
  IF v_target_role = 'admin' THEN
    RETURN;  -- 幂等
  END IF;

  UPDATE pendingbot.group_subject_members
     SET role = 'admin',
         granted_by = v_caller,
         granted_at = now()
   WHERE subject_id = p_group_subject_id
     AND user_id = p_user_id;
END $$;

ALTER FUNCTION pendingbot.grp_promote_to_admin(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_promote_to_admin(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_promote_to_admin(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_promote_to_admin(uuid, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- grp_demote_admin — owner only
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_demote_admin(
  p_group_subject_id uuid,
  p_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_caller_role text;
  v_target_role text;
BEGIN
  PERFORM pendingbot._grp_require_group_subject(p_group_subject_id);

  v_caller_role := pendingbot._grp_caller_role(p_group_subject_id, v_caller);
  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'forbidden: owner required' USING ERRCODE = '42501';
  END IF;

  v_target_role := pendingbot._grp_caller_role(p_group_subject_id, p_user_id);
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'target is not a member' USING ERRCODE = 'P0002';
  END IF;
  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'cannot demote owner' USING ERRCODE = '42501';
  END IF;
  IF v_target_role = 'member' THEN
    RETURN;  -- 幂等
  END IF;

  UPDATE pendingbot.group_subject_members
     SET role = 'member',
         granted_by = v_caller,
         granted_at = now()
   WHERE subject_id = p_group_subject_id
     AND user_id = p_user_id;
END $$;

ALTER FUNCTION pendingbot.grp_demote_admin(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_demote_admin(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_demote_admin(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_demote_admin(uuid, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- grp_transfer_ownership — owner only,转给已经是 member/admin 的 user
-- 原 owner 降为 admin(spec v2 §4.3:转让足够解决继承场景)
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_transfer_ownership(
  p_group_subject_id uuid,
  p_to_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_caller_role text;
  v_target_role text;
BEGIN
  PERFORM pendingbot._grp_require_group_subject(p_group_subject_id);

  v_caller_role := pendingbot._grp_caller_role(p_group_subject_id, v_caller);
  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'forbidden: owner required' USING ERRCODE = '42501';
  END IF;

  IF p_to_user_id = v_caller THEN
    RETURN;  -- 自转,幂等
  END IF;

  v_target_role := pendingbot._grp_caller_role(p_group_subject_id, p_to_user_id);
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'target must already be a member' USING ERRCODE = 'P0002';
  END IF;

  -- 单 owner: 一个事务内降原 owner、升目标
  UPDATE pendingbot.group_subject_members
     SET role = 'admin',
         granted_by = v_caller,
         granted_at = now()
   WHERE subject_id = p_group_subject_id
     AND user_id = v_caller;

  UPDATE pendingbot.group_subject_members
     SET role = 'owner',
         granted_by = v_caller,
         granted_at = now()
   WHERE subject_id = p_group_subject_id
     AND user_id = p_to_user_id;
END $$;

ALTER FUNCTION pendingbot.grp_transfer_ownership(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_transfer_ownership(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_transfer_ownership(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_transfer_ownership(uuid, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- grp_topup_wallet — 所有 role 可调(spec v2 §4.3:充值全员开放)
--
-- 这是「记账」入口 — 真实支付走 IAP / 后台 webhook 时由 service_role 调用,
-- 给 caller-side(authenticated) 暴露是为了未来「应用内自助充值」UX 链路。
-- 不做提现(spec v2 §4.3:无提现,规避金融服务合规风险)。
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.grp_topup_wallet(
  p_group_subject_id uuid,
  p_credits bigint
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := pendingbot._grp_require_caller();
  v_caller_role text;
  v_new_balance bigint;
BEGIN
  PERFORM pendingbot._grp_require_group_subject(p_group_subject_id);

  IF p_credits <= 0 THEN
    RAISE EXCEPTION 'credits must be positive' USING ERRCODE = '22023';
  END IF;

  v_caller_role := pendingbot._grp_caller_role(p_group_subject_id, v_caller);
  -- 全员开放:owner/admin/member 都可以充值(spec v2 §4.3)
  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'forbidden: must be a group member' USING ERRCODE = '42501';
  END IF;

  UPDATE pendingbot.subject_wallets
     SET balance_credits = balance_credits + p_credits,
         lifetime_topup_credits = lifetime_topup_credits + p_credits
   WHERE subject_id = p_group_subject_id
  RETURNING balance_credits INTO v_new_balance;

  IF v_new_balance IS NULL THEN
    -- wallet 行没初始化,补一行
    INSERT INTO pendingbot.subject_wallets(subject_id, balance_credits, lifetime_topup_credits)
    VALUES (p_group_subject_id, p_credits, p_credits)
    RETURNING balance_credits INTO v_new_balance;
  END IF;

  RETURN v_new_balance;
END $$;

ALTER FUNCTION pendingbot.grp_topup_wallet(uuid, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.grp_topup_wallet(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.grp_topup_wallet(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.grp_topup_wallet(uuid, bigint) TO service_role;

COMMIT;
