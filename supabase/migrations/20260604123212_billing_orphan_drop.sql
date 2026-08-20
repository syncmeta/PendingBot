-- #226 — physically retire the orphaned per-conversation 分摊 (group-billing)
-- billing-v1/v2 leftovers. Companion to 20260603112148_drop_billing_v2_orphans.sql,
-- which deferred two tables in its B-segment:
--   "subject_wallets(me.ts getSubjectBalance 仍读)、group_member_billing(invite 流仍写)"
--
-- 前置(硬约束):本迁移**必须在配套 edge 代码部署到生产之后**才 apply ——
--   edge commit「decouple /me/subject + billing from subject_wallets」把 /me/subject
--   的 wallet 读从 subject_wallets 改到 WalletDO,并删了 getSubjectBalance。
--   若提前 apply 而生产仍跑旧 edge,/me/subject 会 500。
--
-- 调查结论(以 live DB 自省 + 全仓 grep 为准,见 task #226 报告):
--
-- A) subject_wallets —— 可安全 DROP。
--    它是 billing-v1 的余额快照,新计费(WalletDO/Polar + pnc_ledger,#207–209)
--    早已不扣减它。唯一活读取是 getSubjectBalance → /me/subject.wallet,而该响应
--    字段无任何客户端解码(iOS CrewSubjectEnvelope 只取 subject),且返回的是过期
--    的 v1 数值。edge 已改源到 WalletDO。三个建主体 RPC 只是在建 subject 时顺手
--    INSERT 一行空钱包(vestigial),改写后不再写;updated_at 同步触发器只在余额
--    变动时触发(已不再发生)。
--
-- B) group_member_billing —— **保留**,不 DROP。
--    该表被多路复用:除了死掉的 per-conversation 分摊列(spent_credits / cap_credits
--    / overdrawn / frozen_at),还承载活字段:
--      * participates —— groups.ts:groupBillingInviteSnapshot 活读(驱动邀请预览
--        文案);join/invite 流(group_join_request_decide / group_invite_link_redeem /
--        groups.ts approve 分支)活写。
--      * muted —— group_set_member_mute 活写(并镜像到 conversation_participants)。
--    因此表不能删。但可以安全退役其上**已死且已半坏**的分摊机械(下方 2)。

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- 1. subject_wallets 退役
-- ─────────────────────────────────────────────────────────────────────

-- 1a. 改写三个建主体 RPC,去掉 subject_wallets 的 vestigial INSERT。
--     其余逻辑逐字保留(以 live DB 自省为准)。

-- ensure_user_subject:不再镜像 users 余额到 subject_wallets;只建/更 subject 行。
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

  INSERT INTO pendingbot.subjects(subject_type, user_id, display_name)
  VALUES ('user_account', p_user_id, v_display_name)
  ON CONFLICT (user_id) WHERE subject_type = 'user_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  RETURN v_subject_id;
END $function$;

-- ensure_group_subject_for_conversation:去掉 subject_wallets INSERT。
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

  INSERT INTO pendingbot.subjects(subject_type, group_conversation_id, display_name)
  VALUES ('group_account', p_conversation_id, v_title)
  ON CONFLICT (group_conversation_id) WHERE subject_type = 'group_account'
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

-- grp_create_group_subject:去掉 subject_wallets INSERT。
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

  INSERT INTO pendingbot.subjects(kind, subject_type, display_name, created_by)
  VALUES ('group_account', 'group_account', v_clean_name, v_caller)
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

-- 1b. 同步触发器 + 触发函数(只服务 subject_wallets)退役。
DROP TRIGGER IF EXISTS subject_wallets_sync_updated_at_trg ON pendingbot.subject_wallets;
DROP FUNCTION IF EXISTS pendingbot.tg_subject_wallets_sync_updated_at() CASCADE;

-- 1c. DROP 表(CASCADE 一并清掉 RLS policy / index / grant)。
--     已确认无视图、无外部 FK 指向它(pg_depend 自省为空)。
DROP TABLE IF EXISTS pendingbot.subject_wallets CASCADE;

-- ─────────────────────────────────────────────────────────────────────
-- 2. group_member_billing 上已死的 per-conversation 分摊机械退役
--    (表保留 —— 见顶部 B;只删死 RPC + 死触发器)
-- ─────────────────────────────────────────────────────────────────────
--
-- 这些 RPC 全仓零调用方(edge + iOS grep 均空),且 apply_audit_split 还引用了
-- 上一迁移已 DROP 的 billing_debit —— 即已半坏,留着只是噪音。
--   * apply_audit_split            —— 旧分摊扣费;调 billing_debit(已删)+ 写
--                                     spent_credits/overdrawn(死列)。
--   * group_set_member_cap         —— 设 cap_credits(死列)。
--   * group_set_member_participates—— 旧分摊开关;participates 现仅由 join/invite
--                                     流写、snapshot 读,不需要这个独立 RPC。
DROP FUNCTION IF EXISTS pendingbot.apply_audit_split(uuid, jsonb) CASCADE;
DROP FUNCTION IF EXISTS pendingbot.group_set_member_cap(uuid, bigint) CASCADE;
DROP FUNCTION IF EXISTS pendingbot.group_set_member_participates(uuid, uuid, boolean) CASCADE;

-- 冻结触发器:仅在 UPDATE OF overdrawn 时触发,而 overdrawn 的唯一写入方是
-- apply_audit_split(刚删)。无活写入方 → 触发器恒不触发,退役。
DROP TRIGGER IF EXISTS group_member_billing_freeze_trg ON pendingbot.group_member_billing;
DROP FUNCTION IF EXISTS pendingbot._group_member_billing_freeze_trigger() CASCADE;

COMMIT;
