-- T4.1 P0 — Session ↔ crew 群聊通信的 RPC 层(spec v2 §9.2/§9.3/§9.4)。
--
-- 现状摘要(已经在更早迁移落地的部分,本文件 *不* 重建):
--   * pendingbot.session_mailbox_items 表 — 由 20260524090046_crew_dispatch_schema.sql 创建,
--     20260524165000_crew_targeted_announcements_master_bot.sql 给它加了
--     announcement_id / sender_kind / sender_member_id / source_message_id 列。
--   * pendingbot.crew_announcements + crew_announcement_mentions — 群聊白板的事实源。
--   * RPC create_crew_announcement / create_crew_announcement_from_runner_for_subject
--     已经覆盖了"人类用户发群聊消息 + fan-out 到 mailbox"和"runner 端 session 通过
--     lease 发消息"两个最常见路径。
--
-- 本次新增,围绕 spec v2 §9 三件事:
--
--   1) RPC `get_crew_whiteboard(p_crew_id, p_since timestamptz?)` — 按时间正序返回 crew
--      白板(board_visible=true)的 announcements + 每条的 mentions,作为 session
--      启动 / 每轮 fresh prompt 前注入的整白板。Caller 走 auth.uid() + 标准 RLS
--      预设(can_view_temporary_group)即可。SECURITY DEFINER + STABLE。
--
--   2) RPC `enqueue_session_mailbox(p_session_id, p_summary, p_message_kind, p_payload,
--      p_source_message_id?)` — 把一条消息精准塞到 *某一个* session 的 mailbox。和
--      create_crew_announcement_for_subject 的区别:
--        - 不创建 announcement 行(不上白板);只往 mailbox 写一条
--        - 接收者是 *一个* session(p_session_id);不做 fan-out
--      用于:用户在群聊里 `@<session>` 时,edge 端解析出 mention,把消息精准送给
--      那个 session(白板那一份由发消息的入口另外写)。
--      校验:caller 必须是该 crew 的 active human member;否则 42501。
--
--   3) ALTER TABLE session_mailbox_items 加 `delivered_at timestamptz` —— 用来记
--      "session 启动时已经把这条注入 prompt context"的时间戳。和老的
--      `read_at`(由 PendingCrew runner 标 read)语义略不同 —— delivered_at 更早:
--      runner 把消息塞进了 prompt;read_at 是 runner 真正确认这条信号被 agent
--      看到了 / 处理了。
--      同时把 status check 扩成 {unread, pending, delivered, read, processed, archived}
--      (老 vocab 保留向后兼容,新 vocab 是 spec v2 草案的 pending/delivered/processed)。
--      默认值不动(unread),最小破坏面。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) session_mailbox_items 扩展:delivered_at + status 词汇表
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.session_mailbox_items
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz;

COMMENT ON COLUMN pendingbot.session_mailbox_items.delivered_at IS
  'Set by /v1/sessions/:id/inbox/mark-delivered when the PendingCrew runner has wrapped this row into the next prompt context. read_at is a stricter signal: agent acknowledged.';

ALTER TABLE pendingbot.session_mailbox_items
  DROP CONSTRAINT IF EXISTS session_mailbox_items_status_check;
ALTER TABLE pendingbot.session_mailbox_items
  ADD CONSTRAINT session_mailbox_items_status_check CHECK (status IN (
    -- legacy vocab (kept for back-compat with rows already written by
    -- create_crew_announcement_for_subject / from-runner variants):
    'unread',
    'read',
    'archived',
    -- new vocab (spec v2 §9.2/§9.3 draft):
    'pending',
    'delivered',
    'processed'
  ));

-- ────────────────────────────────────────────────────────────────────
-- 2) RPC get_crew_whiteboard
--
-- Returns crew_announcements(board_visible = true) joined with their
-- mentions, ordered by created_at ASC. Used by:
--   * Session boot — pull full whiteboard once and inject as prompt
--     context (spec v2 §9.2 "整个群聊白板都注入 session 上下文").
--   * /v1/sessions/:id/inbox endpoint — same payload, plus the per-
--     session mailbox tail.
--
-- p_since: optional cutoff. NULL = full whiteboard. Otherwise only rows
-- with created_at >= p_since are returned (incremental refresh).
--
-- Visibility: SECURITY DEFINER but checks can_view_temporary_group()
-- with auth.uid() before returning anything; an outsider gets an
-- empty array, not an error (mirrors how the existing read-side
-- routes behave).
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.get_crew_whiteboard(uuid, timestamptz);

CREATE OR REPLACE FUNCTION pendingbot.get_crew_whiteboard(
  p_crew_id uuid,
  p_since timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
DECLARE
  caller_id uuid := auth.uid();
  result jsonb;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.can_view_temporary_group(p_crew_id, caller_id) THEN
    -- Out-of-crew caller — return empty array instead of leaking
    -- existence. Mirrors the read-side route convention.
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_yield ORDER BY created_at_to_yield ASC), '[]'::jsonb)
    INTO result
    FROM (
      SELECT
        ann.created_at AS created_at_to_yield,
        jsonb_build_object(
          'id', ann.id,
          'crew_conversation_id', ann.crew_conversation_id,
          'sender_kind', ann.sender_kind,
          'sender_member_id', ann.sender_member_id,
          'sender_session_id', ann.sender_session_id,
          'source_message_id', ann.source_message_id,
          'recipient_mode', ann.recipient_mode,
          'message_kind', ann.message_kind,
          'summary', ann.summary,
          'payload', ann.payload,
          'created_at', ann.created_at,
          'mentions', COALESCE(
            (
              SELECT jsonb_agg(jsonb_build_object(
                  'target_kind', m.target_kind,
                  'target_session_id', m.target_session_id,
                  'target_member_id', m.target_member_id
                ) ORDER BY m.created_at ASC)
                FROM pendingbot.crew_announcement_mentions m
               WHERE m.announcement_id = ann.id
            ),
            '[]'::jsonb
          )
        ) AS row_to_yield
        FROM pendingbot.crew_announcements ann
       WHERE ann.crew_conversation_id = p_crew_id
         AND ann.board_visible = true
         AND (p_since IS NULL OR ann.created_at >= p_since)
    ) sub;

  RETURN result;
END $$;

ALTER FUNCTION pendingbot.get_crew_whiteboard(uuid, timestamptz) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.get_crew_whiteboard(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.get_crew_whiteboard(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.get_crew_whiteboard(uuid, timestamptz) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 3) RPC enqueue_session_mailbox
--
-- Insert ONE row into a single session's mailbox. Does NOT write to
-- crew_announcements (caller has presumably already done that via
-- create_crew_announcement; this RPC is the "now deliver it to one
-- specific session" half).
--
-- Caller must be:
--   * an active human member of the target session's crew, OR
--   * a service-role caller (caller_user_id is null → bypass; useful
--     for the from-runner path which already validated via lease)
--
-- Args:
--   p_session_id        — recipient_session_id
--   p_message_kind      — one of the existing mailbox kinds
--   p_summary           — required, non-empty
--   p_payload           — optional jsonb (defaults to {})
--   p_source_message_id — optional reference back to messages.id (e.g.
--                          the chat message that triggered the enqueue)
--   p_announcement_id   — optional reference back to crew_announcements
--                          (when enqueueing as a follow-up to an
--                           announcement)
-- Returns: the new mailbox row id.
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.enqueue_session_mailbox(uuid, text, text, jsonb, uuid, uuid);

CREATE OR REPLACE FUNCTION pendingbot.enqueue_session_mailbox(
  p_session_id uuid,
  p_message_kind text,
  p_summary text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_source_message_id uuid DEFAULT NULL,
  p_announcement_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  session_row pendingbot.crew_sessions%ROWTYPE;
  sender_member_id uuid;
  summary_text text;
  caller_kind text;
  inserted_id uuid;
BEGIN
  -- Validate inputs
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'session id required' USING ERRCODE = '22023';
  END IF;
  IF p_message_kind NOT IN ('announcement', 'instruction', 'status', 'question', 'handoff', 'result', 'blocker') THEN
    RAISE EXCEPTION 'invalid message kind' USING ERRCODE = '22023';
  END IF;
  summary_text := NULLIF(trim(COALESCE(p_summary, '')), '');
  IF summary_text IS NULL THEN
    RAISE EXCEPTION 'summary required' USING ERRCODE = '22023';
  END IF;

  -- Resolve session
  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0002';
  END IF;

  -- Service-role bypass: no auth.uid() = trusted caller (the edge
  -- service-role client already gated whatever path led here).
  IF caller_id IS NULL THEN
    caller_kind := 'system';
    sender_member_id := NULL;
  ELSE
    -- Auth caller: must be an active human member of the crew
    SELECT id
      INTO sender_member_id
      FROM pendingbot.temporary_group_members
     WHERE conversation_id = session_row.crew_conversation_id
       AND member_kind = 'human'
       AND user_id = caller_id
       AND status = 'active'
     ORDER BY created_at ASC
     LIMIT 1;

    IF sender_member_id IS NULL THEN
      RAISE EXCEPTION 'forbidden: caller is not an active crew member' USING ERRCODE = '42501';
    END IF;
    caller_kind := 'human';
  END IF;

  INSERT INTO pendingbot.session_mailbox_items(
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_member_id,
    recipient_session_id,
    source_message_id,
    announcement_id,
    message_kind,
    summary,
    payload,
    status
  ) VALUES (
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    caller_kind,
    sender_member_id,
    session_row.id,
    p_source_message_id,
    p_announcement_id,
    p_message_kind,
    summary_text,
    COALESCE(p_payload, '{}'::jsonb),
    'unread'
  )
  RETURNING id INTO inserted_id;

  RETURN inserted_id;
END $$;

ALTER FUNCTION pendingbot.enqueue_session_mailbox(uuid, text, text, jsonb, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.enqueue_session_mailbox(uuid, text, text, jsonb, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.enqueue_session_mailbox(uuid, text, text, jsonb, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.enqueue_session_mailbox(uuid, text, text, jsonb, uuid, uuid) TO service_role;

-- ────────────────────────────────────────────────────────────────────
-- 4) RPC mark_session_mailbox_delivered
--
-- Set delivered_at = now() + status = 'delivered' on a batch of mailbox
-- rows. Callable by:
--   * the human controller (auth.uid()) when they own / control the
--     session's responsible_subject (via subject_has_user_access)
--   * service-role (auth.uid() IS NULL) — used by the PendingCrew
--     runner via a device grant, gated upstream in the route handler
--
-- Returns the count of rows actually mutated. Rows that don't belong
-- to the passed session (defensive) are skipped silently.
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pendingbot.mark_session_mailbox_delivered(uuid, uuid[]);

CREATE OR REPLACE FUNCTION pendingbot.mark_session_mailbox_delivered(
  p_session_id uuid,
  p_item_ids uuid[]
) RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  session_row pendingbot.crew_sessions%ROWTYPE;
  affected int := 0;
BEGIN
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'session id required' USING ERRCODE = '22023';
  END IF;
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0002';
  END IF;

  IF caller_id IS NOT NULL THEN
    IF NOT pendingbot.subject_has_user_access(session_row.responsible_subject_id, caller_id) THEN
      RAISE EXCEPTION 'forbidden: caller cannot control session' USING ERRCODE = '42501';
    END IF;
  END IF;

  WITH upd AS (
    UPDATE pendingbot.session_mailbox_items
       SET delivered_at = COALESCE(delivered_at, now()),
           status = CASE
             WHEN status IN ('delivered', 'read', 'processed', 'archived') THEN status
             ELSE 'delivered'
           END
     WHERE recipient_session_id = p_session_id
       AND id = ANY(p_item_ids)
    RETURNING 1
  )
  SELECT count(*)::int INTO affected FROM upd;

  RETURN affected;
END $$;

ALTER FUNCTION pendingbot.mark_session_mailbox_delivered(uuid, uuid[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.mark_session_mailbox_delivered(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.mark_session_mailbox_delivered(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.mark_session_mailbox_delivered(uuid, uuid[]) TO service_role;

COMMIT;
