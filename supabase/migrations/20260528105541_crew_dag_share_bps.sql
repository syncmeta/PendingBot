-- T2.3 — Crew DAG 责任比例边权 + crew_attach_as_child RPC(spec v2 §7.3 规则 1)。
--
-- Schema 现状(已在 20260527090000_crew_dag_captain_responsibility.sql 落地):
--   * crew_parent_links(id, parent_crew_id, child_crew_id, link_kind, created_by_kind,
--     created_by_user_id, created_by_bot_id, responsibility_mode, requires_human_confirmation,
--     confirmed_at, created_at, UNIQUE(parent_crew_id, child_crew_id), CHECK parent<>child)
--   * trigger prevent_crew_parent_cycle BEFORE INSERT/UPDATE — ✅ 已有
--
-- 缺什么:
--   * 边上没有"父在子身上占多少比例"的字段。本迁移加 child_share_bps:
--       「父占的 bps;子保留 10000 - sum(parent's bps)」
--     语义选择(commit message 强调):child_share_bps = 父在子身上的占比 bps
--     ∈ [1, 9999]。严格 1..9999,保证两端都不是全权。
--
-- 新增:
--   1) ALTER TABLE crew_parent_links 加 child_share_bps int CHECK 1..9999
--      老行(没值)给个保守默认 5000 然后 NOT NULL
--   2) 索引 (parent_crew_id)（如未存在则跳过,已存在 crew_parent_links_parent_idx）
--   3) RPC crew_attach_as_child(p_child, p_parent, p_child_keeps_bps)
--      - p_child_keeps_bps ∈ [1, 9999] = 子保留;父占 10000 - p_child_keeps_bps
--      - 权限:caller 必须能"代表 child 的 responsible_subject"(owner|admin)
--      - INSERT crew_parent_links;cycle trigger 把环挡掉
--      - 触发 crew_recompute_shares(p_child) 由 T2.4 实装

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) 给 crew_parent_links 加 child_share_bps
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.crew_parent_links
  ADD COLUMN IF NOT EXISTS child_share_bps integer;

-- 回填:老边按 5000(父子各半)假设,避免破坏 NOT NULL
UPDATE pendingbot.crew_parent_links
   SET child_share_bps = 5000
 WHERE child_share_bps IS NULL;

ALTER TABLE pendingbot.crew_parent_links
  ALTER COLUMN child_share_bps SET NOT NULL;

ALTER TABLE pendingbot.crew_parent_links
  DROP CONSTRAINT IF EXISTS crew_parent_links_child_share_bps_chk;
ALTER TABLE pendingbot.crew_parent_links
  ADD CONSTRAINT crew_parent_links_child_share_bps_chk
  CHECK (child_share_bps > 0 AND child_share_bps < 10000);

COMMENT ON COLUMN pendingbot.crew_parent_links.child_share_bps IS
  'Basis points the parent crew owns of the child (spec v2 §7.3 rule 1). Strictly 1..9999 — never 0% / 100%, so neither side is whole-and-sole responsible.';

-- ────────────────────────────────────────────────────────────────────
-- 2) RPC crew_attach_as_child
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.crew_attach_as_child(
  p_child uuid,
  p_parent uuid,
  p_child_keeps_bps integer
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller            uuid := auth.uid();
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

ALTER FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.crew_attach_as_child(uuid, uuid, integer) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 占位:crew_recompute_shares 由 T2.4 替换;先给一个 no-op 让 T2.3 单独可应用。
-- 用 CREATE FUNCTION 不带 OR REPLACE,如果 T2.4 顺序更后会 OR REPLACE 它。
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.crew_recompute_shares(p_crew_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
BEGIN
  -- T2.3 占位:no-op。T2.4 会替换为真正的实现。
  PERFORM 1;
END $$;

ALTER FUNCTION pendingbot.crew_recompute_shares(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_recompute_shares(uuid) FROM PUBLIC;
-- 不对外暴露 — T2.4 才决定 grant 给谁。

COMMIT;
