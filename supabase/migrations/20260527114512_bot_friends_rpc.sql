-- get_bot_friends(p_bot_id): list a bot's human friends.
--
-- New bot-social-graph rule: a bot's friend list is visible to anyone
-- the bot is in contact with. Concretely the caller can read it iff
-- one of:
--   - caller is the bot's creator (full owner view, incl. for private)
--   - caller is in user_bot_contacts for this bot (caller IS a friend)
--   - caller shares a group conversation with the bot (caller can see
--     who else the bot knows because they already share a room)
--
-- The function does NOT expose any per-pair conversation content or
-- memory — only the public-ish "X added me on <date>" tuple. iOS will
-- back the bot's friend tab with this RPC; the edge `ask_friend` tool
-- uses it server-side to enumerate reachable humans.

BEGIN;

CREATE OR REPLACE FUNCTION pendingbot.get_bot_friends(p_bot_id uuid)
RETURNS TABLE (
  user_id      uuid,
  display_name text,
  avatar_path  text,
  added_at     timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  caller_id uuid := auth.uid();
  bot_row   record;
  allowed   boolean := false;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select id, creator_id, is_active into bot_row
    from pendingbot.bots where id = p_bot_id;

  if bot_row is null or bot_row.is_active = false then
    raise exception 'bot not found or inactive';
  end if;

  -- (1) creator always sees their own bot's friends.
  if bot_row.creator_id is not distinct from caller_id then
    allowed := true;
  end if;

  -- (2) caller is the bot's friend.
  if not allowed and exists (
    select 1 from pendingbot.user_bot_contacts
     where bot_id = p_bot_id and user_id = caller_id
  ) then
    allowed := true;
  end if;

  -- (3) caller shares a group with the bot.
  if not allowed and exists (
    select 1
      from pendingbot.conversation_participants cp_user
      join pendingbot.conversation_participants cp_bot
        on cp_bot.conversation_id = cp_user.conversation_id
      join pendingbot.conversations c
        on c.id = cp_user.conversation_id
     where c.conversation_type = 'group'
       and cp_user.participant_type = 'user' and cp_user.participant_id = caller_id
       and cp_bot.participant_type  = 'bot'  and cp_bot.participant_id  = p_bot_id
  ) then
    allowed := true;
  end if;

  if not allowed then
    raise exception '没有权限查看此机器人的好友';
  end if;

  return query
    select u.id, u.display_name, u.avatar_path, ubc.added_at
      from pendingbot.user_bot_contacts ubc
      join pendingbot.users u on u.id = ubc.user_id
     where ubc.bot_id = p_bot_id
     order by ubc.added_at desc;
end $$;

ALTER FUNCTION pendingbot.get_bot_friends(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.get_bot_friends(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.get_bot_friends(uuid) TO authenticated;

COMMIT;
