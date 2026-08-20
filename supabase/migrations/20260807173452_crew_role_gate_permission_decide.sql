-- Task 5(crew-multi-driver-p1 §1)—— decide_permission_request 的 auth 检查
-- 从"subject-level ACL"换成"四档 crew role"。
--
-- 背景:decide_permission_request(20260705030253 版本)的 Auth check 只认
-- responsible_subject:user_account → 只有 subject.user_id 本人;group_account
-- → subject 侧 owner/admin。Phase 1 的 responsible_subject 固定是 crew
-- 创建者(owner)的个人 user_account subject(见设计文档 §Phase 1),所以在
-- 这版逻辑下,**只有 crew owner 本人**能裁决权限请求——crew admin、以及
-- "自己 session 的发起者(member)"这两档在 spec §1 权限表里明确该放行的
-- 场景,过去这个 RPC 从未真正放行过。
--
-- permission_requests 每一行都挂在一个 crew_session 上
-- (crew_session_id NOT NULL),而 crew_session 又必属于恰好一个 crew
-- (crew_conversation_id),所以这里换成直接查这条请求所属 session 的 crew
-- role,不再绕道 subject:
--   * role IN ('owner','admin') → 放行任意请求
--   * role = 'member' → 仅当该请求所属 session 的 initiating_member_id
--     是自己的活跃 human member 行
--   * role IS NULL / 'observer' → 拒绝
--
-- routes/permission-requests.ts 的 decide 路由 + durable-objects/
-- session-proxy.ts 的 permission.decision 帧处理都已经在 edge 层做了同一套
-- role 判断再调用这个 RPC——这里改的是 RPC 自身的权威判据,两层防御互相独立
-- (edge 层拦下大多数请求,这里是最后一道、也是 WS/HTTP 之外任何直连
-- service-role 调用者都躲不开的一道)。

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.decide_permission_request(p_id uuid, p_decision text, p_caller_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
DECLARE
  req_row pendingbot.permission_requests%ROWTYPE;
  v_crew_conversation_id uuid;
  v_initiating_member_id uuid;
  v_caller_role text;
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

  -- 四档 crew role 判据(spec §1)—— 每条 permission_requests 都挂在一个
  -- crew_session 上,session 又必属于恰好一个 crew。
  SELECT cs.crew_conversation_id, cs.initiating_member_id
    INTO v_crew_conversation_id, v_initiating_member_id
    FROM pendingbot.crew_sessions cs
   WHERE cs.id = req_row.crew_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew session missing for permission request' USING ERRCODE = 'P0002';
  END IF;

  SELECT tgm.role
    INTO v_caller_role
    FROM pendingbot.temporary_group_members tgm
   WHERE tgm.conversation_id = v_crew_conversation_id
     AND tgm.member_kind = 'human'
     AND tgm.user_id = effective_caller
     AND tgm.status = 'active';

  IF v_caller_role IN ('owner', 'admin') THEN
    -- 放行任意请求。
    NULL;
  ELSIF v_caller_role = 'member' THEN
    IF NOT EXISTS (
      SELECT 1
        FROM pendingbot.temporary_group_members m
       WHERE m.id = v_initiating_member_id
         AND m.conversation_id = v_crew_conversation_id
         AND m.member_kind = 'human'
         AND m.user_id = effective_caller
         AND m.status = 'active'
    ) THEN
      RAISE EXCEPTION 'forbidden: member can only decide permission requests for sessions they started' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'forbidden: crew member role required to decide' USING ERRCODE = '42501';
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

COMMIT;
