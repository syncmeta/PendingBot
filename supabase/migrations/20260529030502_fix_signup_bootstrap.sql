-- Fix new-user signup (production onboarding was fully broken).
--
-- Two independent regressions made every NEW account fail:
--
-- Bug A — `column reference "bot_id" is ambiguous` (SQLSTATE 42702) →
--   GoTrue "Database error creating new user".
--   `bootstrap_user_id` gained a local `bot_id uuid` variable (group-template
--   loop), which collided with the pre-existing `where bot_id = target_bot_id`
--   in the user_bot dedup EXISTS (that `bot_id` is the conversations column).
--   plpgsql default `#variable_conflict = error` → raises. Fix: alias the
--   conversations table in that subquery so the column reference is explicit.
--
-- Bug B — `permission denied for function uuidv7` for authenticated/anon.
--   The 20260524175632_harden_function_execute_privileges migration did a
--   blanket `REVOKE EXECUTE ON ALL FUNCTIONS ... FROM anon, public`, which
--   stripped EXECUTE on `pendingbot.uuidv7()`. uuidv7 is used in column
--   DEFAULTs (e.g. id columns); DEFAULT expressions are evaluated with the
--   INSERTing role's privileges, so authenticated/anon inserts into any
--   uuidv7-default table fail. uuidv7 is a pure UUID generator with no data
--   access — safe to expose. Re-grant EXECUTE.

BEGIN;

-- ── Bug A: qualify the ambiguous column ──────────────────────────────
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

    insert into pendingbot.group_billing_config
      (conversation_id, mode, window_seconds, updated_by)
    values
      (conv_id, 'per_head', 86400, p_uid);

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

-- ── Bug B: restore EXECUTE on the uuidv7 utility (used in column defaults) ──
GRANT EXECUTE ON FUNCTION pendingbot.uuidv7() TO authenticated, anon;

COMMIT;
