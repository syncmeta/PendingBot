-- Fix bootstrap_user_id regression introduced in 0057_preset_id_handle.sql.
--
-- 0025 narrowed the seed flow to preset bots only (creator_id IS NULL) and
-- used curated, slug-keyed titles (e.g. "大概介绍这个 App"). 0057 rewrote
-- bootstrap_user_id to add ensure_preset_handle but copied the OLDER body
-- back in: iterating ALL active bots and falling back to random_place_name()
-- for the title. The result is the bug the user just hit on a fresh
-- account — a stack of empty user_bot conversations against every
-- user-created bot in the system, each titled with a random Chinese place
-- name instead of the intended onboarding line.
--
-- This migration restores 0025's preset-only loop + slug-keyed titles
-- while preserving 0057's ensure_preset_handle call.

create or replace function pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) returns void
  language plpgsql security definer
  set search_path to 'pendingbot', 'public'
  as $$
declare
  bot_row record;
  conv_id uuid;
  preset_title text;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  -- Preset random ID — globally unique, immutable, exactly one per user.
  -- (Carried over from 0057.)
  perform pendingbot.ensure_preset_handle(p_uid);

  -- Only seed conversations for *preset* bots (creator_id IS NULL). Bots
  -- owned by other users — even active public ones — must not appear as
  -- empty seeded convs in a new user's list; they should only enter via
  -- explicit action (add friend / browse public).
  for bot_row in
    select id, slug, display_name from pendingbot.bots
     where is_active = true and creator_id is null
  loop
    preset_title := case bot_row.slug
      when 'lorem' then '大概介绍这个 App'
      when 'ipsum' then '公有私有机器人'
      when 'dolor' then '这个 App 八字没一撇呢'
      when 'sit'   then '同一个机器人可以有多个会话/模型'
      when 'amet'  then '我能为你做些什么？'
      else null
    end;

    -- consectetur (GPT) and adipiscing (Gemini) intentionally have no
    -- preset session — they're meant to be discovered, not greeted.
    if preset_title is null then
      continue;
    end if;

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
      ('user_bot', 'message', p_uid, bot_row.id, preset_title)
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, bot_row.id, bot_row.slug);
  end loop;
end $$;
