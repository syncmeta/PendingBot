-- group_remove_member: 补服务端「不能踢 admin」守卫（spec v2 §4.3）
--
-- 权限矩阵明定:owner/admin 可移除普通成员,但 admin 不可被直接移除 ——
-- owner 必须先 demote 再 remove。此前该规则只在 iOS 客户端 canRemove()
-- 预检里挡(2026-07-05 feat/group-subject-client),服务端 RPC 未挡:任何
-- owner/admin 直调本 RPC 可绕过客户端直接踢 admin(tech-debt 2026-07-05
-- 「群账号权限矩阵客户端消费」条记的真安全洞)。本迁移把规则落到服务端,
-- 除新增 admin 守卫外函数体与 20260611013529 版逐字一致。

CREATE OR REPLACE FUNCTION pendingbot.group_remove_member(p_conv_id uuid, p_target_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
declare
  caller_id uuid := auth.uid();
  caller_role text;
  target_role text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select role into caller_role
    from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = caller_id;
  if caller_role is null then
    raise exception 'not a member';
  end if;

  select role into target_role
    from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = p_target_user_id;
  if target_role is null then
    return;  -- already gone, idempotent
  end if;

  -- Self-leave is OK unless caller is owner.
  if caller_id = p_target_user_id then
    if caller_role = 'owner' then
      raise exception 'owner cannot leave; transfer ownership first';
    end if;
  else
    -- Removing someone else: must be owner/admin, and target can't be owner.
    if not (caller_role in ('owner','admin')) then
      raise exception 'forbidden';
    end if;
    if target_role = 'owner' then
      raise exception 'cannot remove the owner';
    end if;
    -- Matrix rule (spec v2 §4.3): admins cannot be removed directly —
    -- the owner must demote them to member first. Without this guard any
    -- admin could kick a fellow admin straight past the client-side check.
    if target_role = 'admin' then
      raise exception 'cannot remove an admin; demote to member first';
    end if;
  end if;

  delete from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = p_target_user_id;
end $function$;
