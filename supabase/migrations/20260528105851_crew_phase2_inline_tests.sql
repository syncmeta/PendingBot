-- T2.1-T2.4 inline smoke tests(DO + ASSERT/RAISE)。
--
-- 这一支迁移只校验 schema 行为;跑完会清掉自己造的所有行。任一 ASSERT 失败 →
-- 整个 BEGIN/COMMIT 包裹 ABORT,db push 不会推过。
--
-- 用 group_account subject(不需要 auth.users FK)做隔离测试。
--
-- 测试目标:
--   1) 创建 2 crew (A/B);attach A as child of B with parent_share=3000
--      → A 的 responsibility shares = subject_b(~3000) + subject_a(~7000),
--      sum=10000,distinct,tiebreaker=subject_a。
--   2) 试 B as child of A(会成环)→ cycle 检测 trigger 抛错。
--   3) crew_propose_split_distinct([50, 50]) → 两个值不等,sum 仍 = 100。

BEGIN;

SET search_path TO pendingbot, public;

DO $$
DECLARE
  v_subject_a uuid;
  v_subject_b uuid;
  v_conv_a uuid;
  v_conv_b uuid;
  v_share_a integer;
  v_share_b integer;
  v_sum integer;
  v_share_count integer;
  v_distinct jsonb;
  v_d0 integer;
  v_d1 integer;
  v_distinct_sum integer;
  v_cycle_raised boolean := false;
BEGIN
  ------------------------------------------------------------------
  -- 准备:两个 group_account subject(无需 auth.users)
  ------------------------------------------------------------------
  INSERT INTO pendingbot.subjects(kind, subject_type, display_name)
  VALUES ('group_account', 'group_account', 'Test Subject A')
  RETURNING id INTO v_subject_a;

  INSERT INTO pendingbot.subjects(kind, subject_type, display_name)
  VALUES ('group_account', 'group_account', 'Test Subject B')
  RETURNING id INTO v_subject_b;

  ------------------------------------------------------------------
  -- 建 crew A / crew B(conversations 表 user_id 可空)
  --   注:initiator_type='bot' 时必须 initiator_bot_id NOT NULL,所以这里
  --   找一个现有 bot id;preset bots(creator_id IS NULL)总是存在。
  --   若无,跳过 initiator 走 INSERT 时 initiator_bot_id=NULL 会违反 check。
  --   改用 initiator_type='human' + 一个虚拟 user_id:不行,需要 auth.users。
  --
  -- 取巧:直接选第一条 pendingbot.bots 当 initiator_bot,做 bot_temporary_group?
  -- 不对,crew 必须 initiator_type='human'。
  --
  -- 折中:直接 INSERT 时禁用相关触发器/约束 — 不行,会污染 schema。
  --
  -- 改:用现有 auth.users 任意一行(prod 数据库一定有 user;空数据库则 skip 整个测试)。
  ------------------------------------------------------------------

  DECLARE
    v_any_user_id uuid;
  BEGIN
    SELECT id INTO v_any_user_id FROM auth.users LIMIT 1;
    IF v_any_user_id IS NULL THEN
      RAISE NOTICE 'no auth.users row; skipping crew DAG/share tests (still running distinct test)';
    ELSE
      INSERT INTO pendingbot.conversations(conversation_type, feature, user_id, title)
      VALUES ('crew', 'message', v_any_user_id, 'Crew A (test)')
      RETURNING id INTO v_conv_a;

      INSERT INTO pendingbot.conversations(conversation_type, feature, user_id, title)
      VALUES ('crew', 'message', v_any_user_id, 'Crew B (test)')
      RETURNING id INTO v_conv_b;

      INSERT INTO pendingbot.temporary_group_meta(
        conversation_id, temporary_kind, responsible_subject_id, initiator_type, initiator_user_id,
        title, status, runtime_kind, runtime_location
      ) VALUES (
        v_conv_a, 'crew', v_subject_a, 'human', v_any_user_id,
        'Crew A', 'active', 'local', 'local_host'
      );

      INSERT INTO pendingbot.temporary_group_meta(
        conversation_id, temporary_kind, responsible_subject_id, initiator_type, initiator_user_id,
        title, status, runtime_kind, runtime_location
      ) VALUES (
        v_conv_b, 'crew', v_subject_b, 'human', v_any_user_id,
        'Crew B', 'active', 'local', 'local_host'
      );

      -- B no parents yet → recompute should give B's subject 10000
      PERFORM pendingbot.crew_recompute_shares(v_conv_b);

      SELECT count(*) INTO v_share_count
        FROM pendingbot.crew_responsibility_shares
       WHERE crew_conversation_id = v_conv_b;
      ASSERT v_share_count = 1, format('Crew B should have 1 share initially, got %s', v_share_count);

      ----------------------------------------------------------------
      -- TEST 1:attach A as child of B with parent_share=3000(child_keeps=7000)
      ----------------------------------------------------------------
      INSERT INTO pendingbot.crew_parent_links(
        parent_crew_id, child_crew_id, link_kind, created_by_kind,
        created_by_user_id, responsibility_mode, child_share_bps
      ) VALUES (
        v_conv_b, v_conv_a, 'parent', 'human', v_any_user_id, 'inherit', 3000
      );

      PERFORM pendingbot.crew_recompute_shares(v_conv_a);

      SELECT count(*) INTO v_share_count
        FROM pendingbot.crew_responsibility_shares
       WHERE crew_conversation_id = v_conv_a;
      ASSERT v_share_count = 2, format('expected 2 shares for A, got %s', v_share_count);

      SELECT share_bps INTO v_share_a
        FROM pendingbot.crew_responsibility_shares
       WHERE crew_conversation_id = v_conv_a AND subject_id = v_subject_a;
      SELECT share_bps INTO v_share_b
        FROM pendingbot.crew_responsibility_shares
       WHERE crew_conversation_id = v_conv_a AND subject_id = v_subject_b;

      ASSERT v_share_a IS NOT NULL, 'subject_a row missing';
      ASSERT v_share_b IS NOT NULL, 'subject_b row missing';

      v_sum := v_share_a + v_share_b;
      ASSERT v_sum = 10000, format('shares sum != 10000, got %s', v_sum);
      ASSERT v_share_a <> v_share_b, format('shares not distinct (a=%s b=%s)', v_share_a, v_share_b);
      ASSERT abs(v_share_a - 7000) <= 2, format('subject_a out of range: %s', v_share_a);
      ASSERT abs(v_share_b - 3000) <= 2, format('subject_b out of range: %s', v_share_b);

      ASSERT EXISTS (
        SELECT 1 FROM pendingbot.crew_responsibility_shares
         WHERE crew_conversation_id = v_conv_a
           AND subject_id = v_subject_a
           AND is_tiebreaker = true
      ), 'subject_a should be tiebreaker';

      ----------------------------------------------------------------
      -- TEST 2:cycle — B as child of A 应抛错
      ----------------------------------------------------------------
      BEGIN
        INSERT INTO pendingbot.crew_parent_links(
          parent_crew_id, child_crew_id, link_kind, created_by_kind,
          created_by_user_id, responsibility_mode, child_share_bps
        ) VALUES (
          v_conv_a, v_conv_b, 'parent', 'human', v_any_user_id, 'inherit', 5000
        );
      EXCEPTION WHEN OTHERS THEN
        v_cycle_raised := true;
      END;
      ASSERT v_cycle_raised, 'expected cycle detection to raise, but INSERT succeeded';

      ----------------------------------------------------------------
      -- 清理 crew 数据
      ----------------------------------------------------------------
      DELETE FROM pendingbot.crew_parent_links
       WHERE child_crew_id IN (v_conv_a, v_conv_b)
          OR parent_crew_id IN (v_conv_a, v_conv_b);
      DELETE FROM pendingbot.crew_responsibility_shares
       WHERE crew_conversation_id IN (v_conv_a, v_conv_b);
      DELETE FROM pendingbot.temporary_group_meta
       WHERE conversation_id IN (v_conv_a, v_conv_b);
      DELETE FROM pendingbot.conversations
       WHERE id IN (v_conv_a, v_conv_b);
    END IF;
  END;

  ------------------------------------------------------------------
  -- TEST 3:crew_propose_split_distinct(独立于 auth.users)
  ------------------------------------------------------------------
  v_distinct := pendingbot.crew_propose_split_distinct(
    jsonb_build_array(
      jsonb_build_object('subject_id', v_subject_a, 'share_bps', 50),
      jsonb_build_object('subject_id', v_subject_b, 'share_bps', 50)
    ),
    0::bigint
  );

  v_d0 := (v_distinct->0->>'share_bps')::integer;
  v_d1 := (v_distinct->1->>'share_bps')::integer;
  v_distinct_sum := v_d0 + v_d1;
  ASSERT v_d0 <> v_d1, format('distinct-ify failed: %s == %s', v_d0, v_d1);
  ASSERT v_distinct_sum = 100, format('distinct-ify sum changed: %s', v_distinct_sum);

  ------------------------------------------------------------------
  -- 清理 subject
  ------------------------------------------------------------------
  DELETE FROM pendingbot.subjects WHERE id IN (v_subject_a, v_subject_b);

  RAISE NOTICE 'T2.1-T2.4 inline tests passed';
END $$;

COMMIT;
