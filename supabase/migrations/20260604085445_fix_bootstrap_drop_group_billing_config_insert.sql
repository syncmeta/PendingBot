-- Fix signup: bootstrap_user_id still inserted into pendingbot.group_billing_config,
-- which was DROPped in 20260603112148 (billing-v2 orphan cleanup). On a fresh DB
-- (the EU rebuild) the table is gone, so every signup hit
--   ERROR: relation "pendingbot.group_billing_config" does not exist
-- inside the AFTER INSERT trigger on auth.users → GoTrue returned
-- "Database error saving new user" (500) and NOBODY could register.
--
-- The drop migration removed the table but missed this function — a billing-
-- retirement loose end that the US DB shares (just never surfaced pre-launch
-- because no real signups ran there). Recreate bootstrap_user_id without the
-- dead insert. Everything else is verbatim from the live definition.
--
-- NOTE: the `group_member_billing` insert below is left intact — that table
-- still exists (B-segment legacy, physical drop tracked in #226). When #226
-- drops it, this function must be updated again to remove that insert too.

CREATE OR REPLACE FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
declare
  tpl record;
  group_tpl record;
  conv_id uuid;
  target_bot_id uuid;
  member_bot_ids uuid[] := '{}';
  slug text;
  bot_id uuid;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  perform pendingbot.ensure_preset_handle(p_uid);

  for tpl in
    select *
      from pendingbot.preset_conversation_templates
     where enabled = true
     order by sort_order, slug
  loop
    target_bot_id := pendingbot._resolve_preset_bot_for_user(tpl.bot_slug, p_uid);
    if target_bot_id is null then
      continue;
    end if;

    -- `c` alias is REQUIRED: a local `bot_id` variable exists in this
    -- function, so an unqualified `bot_id` here is ambiguous (42702).
    if exists (
      select 1 from pendingbot.conversations c
       where c.user_id = p_uid
         and c.bot_id = target_bot_id
         and c.conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title, metadata)
    values
      ('user_bot', 'message', p_uid, target_bot_id, tpl.title,
       jsonb_build_object('source', 'preset_conversation', 'preset_slug', tpl.slug))
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  target_bot_id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, target_bot_id, tpl.slug);
  end loop;

  for group_tpl in
    select *
      from pendingbot.preset_group_templates
     where enabled = true
     order by sort_order, slug
  loop
    if exists (
      select 1 from pendingbot.conversations c
       where c.user_id = p_uid
         and c.conversation_type = 'group'
         and c.metadata->>'source' = 'preset_group'
         and c.metadata->>'preset_slug' = group_tpl.slug
    ) then
      continue;
    end if;

    member_bot_ids := '{}';
    foreach slug in array group_tpl.bot_slugs loop
      bot_id := pendingbot._resolve_preset_bot_for_user(slug, p_uid);
      if bot_id is not null then
        member_bot_ids := array_append(member_bot_ids, bot_id);
      end if;
    end loop;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title, metadata)
    values
      ('group', 'message', p_uid, null, group_tpl.title,
       jsonb_build_object('source', 'preset_group', 'preset_slug', group_tpl.slug))
    returning id into conv_id;

    insert into pendingbot.conversation_group_meta
      (conversation_id, title, join_policy, created_by)
    values
      (conv_id, group_tpl.title, group_tpl.join_policy, p_uid);

    -- [removed] insert into pendingbot.group_billing_config — table dropped in
    -- 20260603112148 (billing-v2 retirement); group billing now runs through
    -- Polar + WalletDO, no per-conversation config row needed.

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner');

    insert into pendingbot.group_member_billing (conversation_id, user_id)
    values (conv_id, p_uid)
    on conflict do nothing;

    foreach bot_id in array member_bot_ids loop
      insert into pendingbot.conversation_participants
        (conversation_id, participant_type, participant_id, role)
      values
        (conv_id, 'bot', bot_id, 'member')
      on conflict do nothing;
    end loop;

    perform pendingbot._seed_preset_group_dialogue(conv_id, p_uid, group_tpl.messages);
  end loop;

  perform pendingbot.ensure_self_conv(p_uid);
  perform pendingbot.seed_example_letter(p_uid);
end $function$;
