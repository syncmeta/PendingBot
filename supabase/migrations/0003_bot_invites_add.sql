-- Adding an invitee to a public_invite bot needs to resolve a handle
-- (which lives behind handles_owner_read RLS — only the handle owner can
-- read it) to a user_id. iOS cannot do that lookup directly, so route
-- it through a SECURITY DEFINER RPC that:
--   1. Verifies the caller is the bot's creator.
--   2. Resolves the handle → user_id.
--   3. UPSERTs bot_invites.
-- Returns the resolved user_id so the client can hydrate the row.

CREATE FUNCTION pendingbot.bot_invites_add(p_bot_id uuid, p_handle text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id  uuid := auth.uid();
  target_uid uuid;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  if not exists (
    select 1 from pendingbot.bots
     where id = p_bot_id and creator_id = caller_id
  ) then
    raise exception '没有权限管理这个机器人';
  end if;

  select user_id into target_uid
    from pendingbot.user_handles
   where value = p_handle and is_active = true
   limit 1;

  if target_uid is null then
    raise exception '号码无效或已撤销';
  end if;

  if target_uid = caller_id then
    raise exception '不需要邀请自己';
  end if;

  insert into pendingbot.bot_invites (bot_id, user_id)
  values (p_bot_id, target_uid)
  on conflict do nothing;

  return target_uid;
end $$;

ALTER FUNCTION pendingbot.bot_invites_add(p_bot_id uuid, p_handle text) OWNER TO postgres;
