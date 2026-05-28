-- T2.4 — 责任比例 5 规则(spec v2 §7.3)。
--
-- 5 条规则:
--   1) 创建子 crew 时,父决定"父在子身上占 child_share_bps"(T2.3 已落)。
--   2) 子的最终 shares = (各父的 resolved shares × 该父在子身上的占比 ÷ 10000)
--      按 subject 合并 + (子自留 = 10000 - sum(child_share_bps over parents))归给
--      子自己的 responsible_subject。归一化到 sum=10000。
--   3) 同一 subject 在多条祖先链上汇合 → 合并(SUM)。
--   4) 跨主体调整需所有涉及 subject 都批准(本迁移只落 schema + stub,UI 后接)。
--   5) 拍板原则:share_bps 最大者拥有最终决定权(is_tiebreaker=true),由
--      crew_recompute_tiebreaker 维护。
--
-- 本迁移:
--   * ALTER crew_responsibility_shares 加 is_tiebreaker boolean DEFAULT false;
--     部分唯一索引保证每个 crew 至多一行 tiebreaker。
--   * crew_propose_split_distinct(jsonb, bigint) → jsonb:确定性微调把相同 bps
--     变成两两不等(保 sum 不变)。
--   * crew_recompute_shares(uuid):实装(替换 T2.3 的 no-op)。
--   * crew_recompute_tiebreaker(uuid):实装。
--   * crew_pending_share_changes 表 + stub RPCs(propose / approve)。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) is_tiebreaker
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.crew_responsibility_shares
  ADD COLUMN IF NOT EXISTS is_tiebreaker boolean NOT NULL DEFAULT false;

DROP INDEX IF EXISTS pendingbot.crew_responsibility_shares_tiebreaker_uniq;
CREATE UNIQUE INDEX crew_responsibility_shares_tiebreaker_uniq
  ON pendingbot.crew_responsibility_shares(crew_conversation_id)
  WHERE is_tiebreaker;

COMMENT ON COLUMN pendingbot.crew_responsibility_shares.is_tiebreaker IS
  'spec v2 §7.3 rule 5: at most one row per crew where is_tiebreaker=true, marking the subject with the highest share_bps (who has final say).';

-- ────────────────────────────────────────────────────────────────────
-- 2) crew_propose_split_distinct(p_shares jsonb, p_seed bigint) → jsonb
--    输入: [{subject_id, share_bps}, ...]
--    输出: 同 schema,但任两 share_bps 不等;sum 保持不变;同样 input/seed → 同样 output。
--    策略:稳定排序 → 对相邻重复元素 ±1 调整(把"靠后的"+1、再从"靠前的"-1 平衡),
--          只在区间 [1, 9999] 内动,失败抛错。
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.crew_propose_split_distinct(
  p_shares jsonb,
  p_seed bigint DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_arr   jsonb := COALESCE(p_shares, '[]'::jsonb);
  v_len   integer := jsonb_array_length(v_arr);
  v_out   jsonb;
  i       integer;
  j       integer;
  v_a     integer;
  v_b     integer;
  v_pivot integer;
  v_sum_in  bigint := 0;
  v_sum_out bigint := 0;
BEGIN
  IF v_len <= 1 THEN
    RETURN v_arr;
  END IF;

  -- 拷出可变数组(用 jsonb_build_array 构造 result)
  -- 把 (subject_id, share_bps) 提到一个 SQL 数组里,按 subject_id::text 稳定排序
  WITH src AS (
    SELECT
      (elem->>'subject_id')::uuid AS subject_id,
      (elem->>'share_bps')::integer AS share_bps,
      ord
    FROM jsonb_array_elements(v_arr) WITH ORDINALITY AS t(elem, ord)
  )
  SELECT jsonb_agg(jsonb_build_object(
           'subject_id', subject_id,
           'share_bps',  share_bps
         ) ORDER BY subject_id::text)
    INTO v_out
    FROM src;

  -- sum 校验
  SELECT COALESCE(sum((elem->>'share_bps')::integer), 0) INTO v_sum_in
    FROM jsonb_array_elements(v_arr) AS elem;

  -- 扫一遍,出现 v_out[i].share_bps == v_out[i+1].share_bps 就把 i+1 +1、再从最后一个 -1 平衡
  -- 用 p_seed 决定方向(向上/向下),这里简单用 seed 的奇偶
  i := 0;
  WHILE i < v_len - 1 LOOP
    v_a := (v_out->i->>'share_bps')::integer;
    v_b := (v_out->(i+1)->>'share_bps')::integer;
    IF v_a = v_b THEN
      -- 把 i+1 += 1,从某个 j ≠ i+1 -= 1 维持 sum
      -- 选 j = 最后一个(v_len-1);若 j == i+1 选倒数第二个;且 j 上 share>1 才能 -1
      j := v_len - 1;
      IF j = (i + 1) THEN
        j := j - 1;
      END IF;
      -- p_seed 偶数 → +1 在 i+1,-1 在 j;奇数 → +1 在 j,-1 在 i+1(只要可行)
      IF (p_seed % 2) = 0 AND ((v_out->(i+1)->>'share_bps')::integer < 9999)
         AND ((v_out->j->>'share_bps')::integer > 1) THEN
        v_out := jsonb_set(v_out, ARRAY[(i+1)::text, 'share_bps'],
                           to_jsonb(((v_out->(i+1)->>'share_bps')::integer) + 1));
        v_out := jsonb_set(v_out, ARRAY[j::text, 'share_bps'],
                           to_jsonb(((v_out->j->>'share_bps')::integer) - 1));
      ELSIF ((v_out->j->>'share_bps')::integer < 9999)
         AND ((v_out->(i+1)->>'share_bps')::integer > 1) THEN
        v_out := jsonb_set(v_out, ARRAY[j::text, 'share_bps'],
                           to_jsonb(((v_out->j->>'share_bps')::integer) + 1));
        v_out := jsonb_set(v_out, ARRAY[(i+1)::text, 'share_bps'],
                           to_jsonb(((v_out->(i+1)->>'share_bps')::integer) - 1));
      ELSE
        RAISE EXCEPTION 'cannot distinct-ify shares; all values near boundary' USING ERRCODE = '22023';
      END IF;
    END IF;
    i := i + 1;
  END LOOP;

  -- sum 校验
  SELECT COALESCE(sum((elem->>'share_bps')::integer), 0) INTO v_sum_out
    FROM jsonb_array_elements(v_out) AS elem;

  IF v_sum_in <> v_sum_out THEN
    RAISE EXCEPTION 'distinct-ify changed sum (% → %)', v_sum_in, v_sum_out USING ERRCODE = 'XX000';
  END IF;

  RETURN v_out;
END $$;

ALTER FUNCTION pendingbot.crew_propose_split_distinct(jsonb, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_propose_split_distinct(jsonb, bigint) FROM PUBLIC;
-- 只允许 service_role / 内部 / SECURITY DEFINER 函数调用
GRANT EXECUTE ON FUNCTION pendingbot.crew_propose_split_distinct(jsonb, bigint) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 3) crew_recompute_tiebreaker(p_crew_id)
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.crew_recompute_tiebreaker(p_crew_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_max_subject uuid;
BEGIN
  -- 找最大 share_bps 的 subject(平票按 subject_id::text 升序作 deterministic fallback)
  SELECT subject_id
    INTO v_max_subject
    FROM pendingbot.crew_responsibility_shares
   WHERE crew_conversation_id = p_crew_id
   ORDER BY share_bps DESC, subject_id::text ASC
   LIMIT 1;

  -- 先全部置 false,再单独置 true,保证唯一索引不冲突
  UPDATE pendingbot.crew_responsibility_shares
     SET is_tiebreaker = false
   WHERE crew_conversation_id = p_crew_id
     AND is_tiebreaker;

  IF v_max_subject IS NOT NULL THEN
    UPDATE pendingbot.crew_responsibility_shares
       SET is_tiebreaker = true
     WHERE crew_conversation_id = p_crew_id
       AND subject_id = v_max_subject;
  END IF;
END $$;

ALTER FUNCTION pendingbot.crew_recompute_tiebreaker(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_recompute_tiebreaker(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_recompute_tiebreaker(uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 4) crew_recompute_shares(p_crew_id) — 实装(替换 T2.3 的 no-op)
--
-- 算法:
--   - 取所有父边 (parent_crew_id, child_share_bps),其中 child_share_bps 是
--     "父在子身上的占比"(spec v2 §7.3 规则 1,T2.3 落定)。
--   - 取每个父的 resolved shares(递归读其 crew_responsibility_shares;若该父没有
--     explicit shares,fall back 到它的 responsible_subject 全 10000)。
--   - 父 p 对子的 subject s 的贡献 = R_p[s] × edge_bps_p ÷ 10000(其中 R_p[s] 是 bps)。
--   - 子自留 = 10000 - sum(edge_bps_p) → 归给子自己的 responsible_subject_id。
--   - 按 subject 求和后归一化到 sum=10000(整数误差到最大那一行)。
--   - 调 crew_propose_split_distinct 把相同值拆开。
--   - DELETE 现有 + INSERT 新 + crew_recompute_tiebreaker。
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.crew_recompute_shares(p_crew_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_child_subject_id uuid;
  v_parents_total_bps bigint;
  v_child_keeps_bps bigint;
  v_sum_after_blend bigint;
  v_distinct jsonb;
  v_rec jsonb;
BEGIN
  -- 子的 responsible_subject(自留份额归它)
  SELECT responsible_subject_id
    INTO v_child_subject_id
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_crew_id
     AND temporary_kind = 'crew';

  IF v_child_subject_id IS NULL THEN
    -- 不是 crew 行,no-op
    RETURN;
  END IF;

  -- 父边总占比
  SELECT COALESCE(sum(child_share_bps), 0)
    INTO v_parents_total_bps
    FROM pendingbot.crew_parent_links
   WHERE child_crew_id = p_crew_id;

  IF v_parents_total_bps >= 10000 THEN
    -- 异常:父占满或超过(单边 1..9999 已挡,但多边累计有可能。这种情况下保留=0,
    -- 直接按比例归一化,不留给 child subject)
    v_child_keeps_bps := 0;
  ELSE
    v_child_keeps_bps := 10000 - v_parents_total_bps;
  END IF;

  -- 计算 raw blended(暂存到一个 CTE 风格的 temp 表里)
  CREATE TEMP TABLE IF NOT EXISTS _blend (subject_id uuid PRIMARY KEY, bps numeric) ON COMMIT DROP;
  DELETE FROM _blend;

  -- 父贡献
  INSERT INTO _blend(subject_id, bps)
  SELECT s.subject_id, sum(s.contrib) AS bps
    FROM (
      SELECT
        crs.subject_id,
        (crs.share_bps::numeric * cpl.child_share_bps::numeric / 10000.0) AS contrib
        FROM pendingbot.crew_parent_links cpl
        JOIN pendingbot.crew_responsibility_shares crs
          ON crs.crew_conversation_id = cpl.parent_crew_id
       WHERE cpl.child_crew_id = p_crew_id

      UNION ALL

      -- 父没有 explicit shares → 用其 responsible_subject 兜底(legacy/root)
      SELECT
        pmeta.responsible_subject_id AS subject_id,
        cpl.child_share_bps::numeric AS contrib
        FROM pendingbot.crew_parent_links cpl
        JOIN pendingbot.temporary_group_meta pmeta
          ON pmeta.conversation_id = cpl.parent_crew_id
         AND pmeta.temporary_kind = 'crew'
       WHERE cpl.child_crew_id = p_crew_id
         AND NOT EXISTS (
           SELECT 1 FROM pendingbot.crew_responsibility_shares crs2
            WHERE crs2.crew_conversation_id = cpl.parent_crew_id
         )
    ) s
   GROUP BY s.subject_id;

  -- 子自留贡献(归一化前累加;若 subject 已在 _blend 则合并)
  IF v_child_keeps_bps > 0 THEN
    INSERT INTO _blend(subject_id, bps)
    VALUES (v_child_subject_id, v_child_keeps_bps::numeric)
    ON CONFLICT (subject_id) DO UPDATE SET bps = _blend.bps + EXCLUDED.bps;
  END IF;

  -- 若 _blend 完全空(根 crew,没父也没自留 — 不可能,自留 = 10000)→ 给 child_subject 10000
  IF NOT EXISTS (SELECT 1 FROM _blend) THEN
    INSERT INTO _blend(subject_id, bps) VALUES (v_child_subject_id, 10000.0);
  END IF;

  SELECT sum(bps) INTO v_sum_after_blend FROM _blend;

  -- 归一化到 sum=10000(每行四舍五入到整数;误差挪到最大行)
  CREATE TEMP TABLE IF NOT EXISTS _normalized (subject_id uuid PRIMARY KEY, share_bps integer) ON COMMIT DROP;
  DELETE FROM _normalized;

  INSERT INTO _normalized(subject_id, share_bps)
  SELECT subject_id,
         GREATEST(1, round(bps * 10000.0 / v_sum_after_blend)::integer)
    FROM _blend;

  -- 修正 rounding 误差 → 把差量加/减到最大行
  DECLARE
    v_diff integer;
    v_max_subject uuid;
  BEGIN
    SELECT (10000 - sum(share_bps))::integer INTO v_diff FROM _normalized;
    IF v_diff <> 0 THEN
      SELECT subject_id INTO v_max_subject
        FROM _normalized
       ORDER BY share_bps DESC, subject_id::text ASC
       LIMIT 1;
      UPDATE _normalized SET share_bps = share_bps + v_diff WHERE subject_id = v_max_subject;
    END IF;
  END;

  -- 转 jsonb 给 distinct-ifier
  SELECT jsonb_agg(jsonb_build_object('subject_id', subject_id, 'share_bps', share_bps))
    INTO v_distinct
    FROM _normalized;

  -- 只有 >1 行时才需要 distinct-ify
  IF jsonb_array_length(v_distinct) > 1 THEN
    v_distinct := pendingbot.crew_propose_split_distinct(v_distinct, 0::bigint);
  END IF;

  -- 落表:DELETE + INSERT
  DELETE FROM pendingbot.crew_responsibility_shares
   WHERE crew_conversation_id = p_crew_id;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_distinct) LOOP
    INSERT INTO pendingbot.crew_responsibility_shares(
      crew_conversation_id, subject_id, share_bps, source, is_tiebreaker
    ) VALUES (
      p_crew_id,
      (v_rec->>'subject_id')::uuid,
      (v_rec->>'share_bps')::integer,
      'explicit',
      false
    );
  END LOOP;

  -- tiebreaker
  PERFORM pendingbot.crew_recompute_tiebreaker(p_crew_id);

  -- 清理 temp(ON COMMIT DROP 兜底,这里手动 TRUNCATE 保平衡多次调用)
  TRUNCATE _blend, _normalized;
END $$;

ALTER FUNCTION pendingbot.crew_recompute_shares(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_recompute_shares(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_recompute_shares(uuid) TO service_role;
-- 不 grant authenticated:客户端不直接调,改 shares 走 attach_as_child / propose_share_change。

-- ────────────────────────────────────────────────────────────────────
-- 5) 跨主体确认 — schema + stub RPCs(规则 4)
-- ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS pendingbot.crew_pending_share_changes (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  proposed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  proposal_payload jsonb NOT NULL,
  requires_subject_approvals uuid[] NOT NULL,
  approvals jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz
);

CREATE INDEX IF NOT EXISTS crew_pending_share_changes_crew_idx
  ON pendingbot.crew_pending_share_changes(crew_id, status, created_at DESC);

ALTER TABLE pendingbot.crew_pending_share_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crew_pending_share_changes_view ON pendingbot.crew_pending_share_changes;
CREATE POLICY crew_pending_share_changes_view
  ON pendingbot.crew_pending_share_changes FOR SELECT TO authenticated
  USING (pendingbot.can_view_temporary_group(crew_id, auth.uid()));

GRANT SELECT ON TABLE pendingbot.crew_pending_share_changes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.crew_pending_share_changes TO service_role;

-- propose stub:caller 必须能看 crew(can_view_temporary_group);把提案登记,不动 shares
CREATE OR REPLACE FUNCTION pendingbot.crew_propose_share_change(
  p_crew_id uuid,
  p_proposal_payload jsonb,
  p_requires_subject_approvals uuid[]
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := auth.uid();
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

ALTER FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.crew_propose_share_change(uuid, jsonb, uuid[]) TO service_role;

-- approve stub:caller 必须能代表某个 required subject;把它登记进 approvals。
-- 不在 stub 里 apply proposal_payload(等下个 phase 接 UI)。
CREATE OR REPLACE FUNCTION pendingbot.crew_approve_share_change(
  p_change_id uuid,
  p_subject_id uuid
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_required uuid[];
  v_approvals jsonb;
  v_status text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;

  IF NOT pendingbot._crew_caller_can_act_for_subject(p_subject_id, v_caller) THEN
    RAISE EXCEPTION 'forbidden: caller cannot act for subject' USING ERRCODE = '42501';
  END IF;

  SELECT requires_subject_approvals, approvals, status
    INTO v_required, v_approvals, v_status
    FROM pendingbot.crew_pending_share_changes
   WHERE id = p_change_id
     FOR UPDATE;

  IF v_required IS NULL THEN
    RAISE EXCEPTION 'change not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'change already decided (%)' , v_status USING ERRCODE = '22023';
  END IF;

  IF NOT (p_subject_id = ANY(v_required)) THEN
    RAISE EXCEPTION 'subject not in required approvals' USING ERRCODE = '22023';
  END IF;

  v_approvals := COALESCE(v_approvals, '{}'::jsonb)
              || jsonb_build_object(p_subject_id::text, jsonb_build_object(
                   'by_user_id', v_caller,
                   'at', now()
                 ));

  UPDATE pendingbot.crew_pending_share_changes
     SET approvals = v_approvals
   WHERE id = p_change_id;

  -- 如果所有 required 都已批准,标记 approved(但不 apply payload — 等下个 phase)
  IF (
    SELECT COALESCE(bool_and(v_approvals ? s::text), false)
      FROM unnest(v_required) AS t(s)
  ) THEN
    UPDATE pendingbot.crew_pending_share_changes
       SET status = 'approved', decided_at = now()
     WHERE id = p_change_id;
    RETURN 'approved';
  END IF;

  RETURN 'pending';
END $$;

ALTER FUNCTION pendingbot.crew_approve_share_change(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.crew_approve_share_change(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.crew_approve_share_change(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.crew_approve_share_change(uuid, uuid) TO service_role;

COMMIT;
