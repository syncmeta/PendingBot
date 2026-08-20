-- Listing invitees needs to join bot_invites → pendingbot.users.display_name
-- but users_self_read locks users to "read your own row only", so the bot
-- creator can't see their invitees' names directly. Open a narrow window:
-- a SECURITY DEFINER RPC that returns (user_id, display_name, invited_at)
-- only when the caller is the bot's creator.

CREATE FUNCTION pendingbot.list_bot_invitees(p_bot_id uuid)
  RETURNS TABLE (user_id uuid, display_name text, invited_at timestamptz)
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pendingbot', 'public'
  AS $$
declare
  caller_id uuid := auth.uid();
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

  return query
    select bi.user_id, coalesce(u.display_name, '') as display_name, bi.invited_at
      from pendingbot.bot_invites bi
      left join pendingbot.users u on u.id = bi.user_id
     where bi.bot_id = p_bot_id
     order by bi.invited_at desc;
end $$;

ALTER FUNCTION pendingbot.list_bot_invitees(p_bot_id uuid) OWNER TO postgres;
