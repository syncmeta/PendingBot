-- Self-chat: user can talk to a bot that's been seeded with their own
-- bio as its persona ("a mirror conversation"). One singleton conv per
-- user, lazily materialised on first tap from the friends-tab self row.
--
-- Model is fixed to deepseek-v4-pro (preset bot slug = 'ipsum').

-- 1. Add 'self' to the conversation_type check constraint.
alter table pendingbot.conversations
  drop constraint if exists conversations_conversation_type_check;
alter table pendingbot.conversations
  add constraint conversations_conversation_type_check
    check (conversation_type in ('user_bot', 'user_user', 'group',
                                 'discuss', 'surf', 'portrait', 'self'));

-- 2. open_self_conv() RPC. Find-or-create the singleton self-chat for
-- the caller. Returns the conv id either way.
create or replace function pendingbot.open_self_conv()
returns uuid
language plpgsql
security definer
set search_path = pendingbot, public
as $$
declare
  caller_id uuid := auth.uid();
  bot_uuid  uuid;
  conv_id   uuid;
  caller_name text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select id into bot_uuid
    from pendingbot.bots
   where slug = 'ipsum' and is_active = true
   limit 1;
  if bot_uuid is null then
    raise exception 'self-chat bot (slug=ipsum) not configured';
  end if;

  -- Reuse if a self conv already exists for this user.
  select id into conv_id
    from pendingbot.conversations
   where user_id = caller_id and conversation_type = 'self'
   limit 1;
  if conv_id is not null then
    return conv_id;
  end if;

  select coalesce(nullif(display_name, ''), '你') into caller_name
    from pendingbot.users where id = caller_id;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('self', 'message', caller_id, bot_uuid, coalesce(caller_name, '我自己'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  bot_uuid,  'member');

  return conv_id;
end $$;

grant execute on function pendingbot.open_self_conv() to authenticated;
