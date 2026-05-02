-- Conversation titles default to a random place name (from
-- pendingbot.place_names) instead of the bot's display_name. Applies to
-- both server-side creation paths:
--   * bootstrap_user_id   — first-sign-in seeded user_bot convs
--   * open_user_bot_conv  — RPC iOS calls when a friend tap materialises
--
-- Backfill existing convs so users who already signed up get a place
-- name instead of the bot name they currently see.

create or replace function pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb)
returns void
language plpgsql
security definer
set search_path = pendingbot, public
as $$
declare
  bot_row record;
  conv_id uuid;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  for bot_row in
    select id, slug, display_name from pendingbot.bots where is_active = true
  loop
    if exists (
      select 1 from pendingbot.conversations
       where user_id = p_uid
         and bot_id = bot_row.id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title)
    values
      ('user_bot', 'message', p_uid, bot_row.id,
       coalesce(pendingbot.random_place_name(), bot_row.display_name))
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, bot_row.id, bot_row.slug);
  end loop;
end $$;

create or replace function pendingbot.open_user_bot_conv(p_bot_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pendingbot, public
as $$
declare
  caller_id uuid := auth.uid();
  conv_id   uuid;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  if not exists (select 1 from pendingbot.bots where id = p_bot_id and is_active = true) then
    raise exception 'bot not found or inactive';
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('user_bot', 'message', caller_id, p_bot_id,
     coalesce(pendingbot.random_place_name(), '新对话'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  p_bot_id,  'member');

  return conv_id;
end $$;

grant execute on function pendingbot.open_user_bot_conv(uuid) to authenticated;

-- random_place_name() is marked stable, which collapses to one value
-- across a single UPDATE — fine for new-row creation but wrong for the
-- backfill below where every conv should pick its own. Mark VOLATILE
-- and pin the volatility back per call.
create or replace function pendingbot.random_place_name() returns text
language sql
volatile
as $$
  select name from pendingbot.place_names order by random() limit 1;
$$;

-- Backfill: re-title any existing user_bot conv whose current title is
-- the matching bot's display_name (i.e. it was created before this
-- migration). Skip convs the user has manually renamed.
update pendingbot.conversations c
   set title = pendingbot.random_place_name()
  from pendingbot.bots b
 where c.bot_id = b.id
   and c.conversation_type = 'user_bot'
   and c.title = b.display_name;
