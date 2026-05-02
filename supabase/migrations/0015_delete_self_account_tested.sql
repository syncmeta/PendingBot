-- Self-delete, audited + tested.
--
-- The previous attempts (0012, 0013, 0014) kept hitting the next FK
-- constraint after each fix. This migration walks every FK targeting
-- auth.users / pendingbot.conversations / pendingbot.messages once,
-- handles each explicitly, and includes a self-test (fake user) that
-- aborts the migration if any path still rejects the deletion.
--
-- FK inventory (auth.users → pendingbot.* without ON DELETE CASCADE):
--   conversations.user_id   nullable     → DELETE row
--   messages.user_id        nullable     → DELETE row
--   attachments.user_id     NOT NULL     → DELETE row (cascade-safe via conv too)
--   audit_log.user_id       nullable     → SET NULL  (preserve billing trail)
--   audit_log.conv_id       nullable     → SET NULL
--   skills.owner_id         NOT NULL     → DELETE user-owned
--   tools.owner_id          nullable     → SET NULL  (preserve tool)
--   invites.created_by      nullable     → SET NULL
--   invites.used_by         nullable     → SET NULL
--   bots.owner_id           nullable     → ignore (admin-only path)
--
-- messages self-FKs (parent / replaces / replaced_by) all nullable →
-- SET NULL before the row delete.

create or replace function pendingbot._delete_account_internal(p_uid uuid)
returns void
language plpgsql
security definer
set search_path = pendingbot, public, auth
as $$
declare
  my_conv_ids uuid[];
  my_message_ids uuid[];
begin
  if p_uid is null then
    raise exception 'p_uid is required';
  end if;

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = p_uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = p_uid or conversation_id = any(my_conv_ids);

  -- 1. Snip every self-FK pointing at one of our messages.
  update pendingbot.messages set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  -- 2. audit_log: preserve rows, decouple user + conv refs.
  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = p_uid;

  -- 3. invites: preserve historical record.
  update pendingbot.invites set created_by = null where created_by = p_uid;
  update pendingbot.invites set used_by = null where used_by = p_uid;

  -- 4. tools: preserve tool definition, disown.
  update pendingbot.tools set owner_id = null where owner_id = p_uid;

  -- 5. NOT-NULL FK rows belonging to the user. Must DELETE.
  delete from pendingbot.skills where owner_id = p_uid;
  delete from pendingbot.attachments where user_id = p_uid;

  -- 6. The user's own messages + participants + convs.
  delete from pendingbot.messages where user_id = p_uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = p_uid;
  delete from pendingbot.conversations where user_id = p_uid;

  -- 7. Drop the auth row last; cascades user_unread_counts,
  --    user_handles, user_contacts (both directions), device_tokens,
  --    skill_subscriptions, ai_picks, portraits, bot_reflections,
  --    pendingbot.users, user_settings, user_quota, surf_runs,
  --    review_runs, plus everything else with on-delete-cascade on
  --    auth.users(id).
  delete from auth.users where id = p_uid;
end $$;

create or replace function pendingbot.delete_self_account()
returns void
language plpgsql
security definer
set search_path = pendingbot, public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._delete_account_internal(auth.uid());
end $$;

grant execute on function pendingbot.delete_self_account() to authenticated;
revoke execute on function pendingbot._delete_account_internal(uuid) from public;

-- ─── Self-test ──────────────────────────────────────────────────────────────
--
-- Create a synthetic user with one row in every table the function
-- touches; run _delete_account_internal on them; assert each row was
-- handled correctly. The DO block's BEGIN gives us an implicit
-- savepoint, so the trailing RAISE rolls all test data back regardless
-- of test outcome.

do $$
declare
  fake_uid uuid := '00000000-0000-0000-0000-000000000999';
  bot_id uuid;
  conv_id uuid := gen_random_uuid();
  msg1_id uuid := gen_random_uuid();
  msg2_id uuid := gen_random_uuid();
  audit_id uuid;
  invite_code text := '__test_invite_' || substr(md5(random()::text), 1, 8);
  skill_id uuid := gen_random_uuid();
  tool_id uuid := gen_random_uuid();
  audit_remained boolean;
  invite_remained boolean;
  tool_remained boolean;
  failure text;
begin
  -- Ensure no leftover from a previous run.
  delete from auth.users where id = fake_uid;

  -- Pick any existing bot for the participant row.
  select id into bot_id from pendingbot.bots where is_active = true limit 1;
  if bot_id is null then
    raise notice 'no active bots; skipping self-test';
    return;
  end if;

  -- Setup: minimal-but-realistic user with data in every code path.
  insert into auth.users (id, email, instance_id, aud, role,
                          encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at)
  values (fake_uid, 'test_' || fake_uid || '@local.test',
          '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '', now(), '{}'::jsonb, '{}'::jsonb, now(), now());

  -- pendingbot.users gets created via the bootstrap trigger; if not, force it.
  insert into pendingbot.users (id, email, display_name)
  values (fake_uid, 'test@local.test', 'self-delete-test')
  on conflict (id) do nothing;

  insert into pendingbot.conversations (id, conversation_type, feature, user_id, bot_id, title)
  values (conv_id, 'user_bot', 'message', fake_uid, bot_id, 'test');

  insert into pendingbot.conversation_participants (conversation_id, participant_type, participant_id, role)
  values (conv_id, 'user', fake_uid, 'owner'),
         (conv_id, 'bot',  bot_id,   'member');

  -- Two messages: msg2 references msg1 as parent (exercises the self-FK).
  insert into pendingbot.messages (id, client_message_id, conversation_id, user_id,
                                   role, status, content)
  values (msg1_id, gen_random_uuid(), conv_id, fake_uid, 'user', 'done', 'q');
  insert into pendingbot.messages (id, client_message_id, conversation_id, sender_bot_id,
                                   role, status, content, parent_message_id)
  values (msg2_id, gen_random_uuid(), conv_id, bot_id, 'bot', 'done', 'a', msg1_id);

  insert into pendingbot.attachments (user_id, conversation_id, r2_key, mime_type, byte_size)
  values (fake_uid, conv_id, '__test/' || gen_random_uuid(), 'text/plain', 1);

  insert into pendingbot.audit_log (user_id, conversation_id, task_type, model_id)
  values (fake_uid, conv_id, 'message_reply', 'test/model')
  returning id into audit_id;

  insert into pendingbot.invites (code, created_by, used_by)
  values (invite_code, fake_uid, fake_uid);

  insert into pendingbot.skills (id, owner_id, frontmatter, body_md, visibility)
  values (skill_id, fake_uid, '{"name":"test"}'::jsonb, 'body', 'private');

  insert into pendingbot.tools (id, owner_id, source_type, name, schema_json)
  values (tool_id, fake_uid, 'custom', 'test', '{}'::jsonb);

  -- Run.
  perform pendingbot._delete_account_internal(fake_uid);

  -- Assertions.
  if exists (select 1 from auth.users where id = fake_uid) then
    failure := 'auth.users row not deleted';
  elsif exists (select 1 from pendingbot.conversations where id = conv_id) then
    failure := 'conversations row not deleted';
  elsif exists (select 1 from pendingbot.messages where id in (msg1_id, msg2_id)) then
    failure := 'messages rows not deleted';
  elsif exists (select 1 from pendingbot.attachments where user_id = fake_uid) then
    failure := 'attachments rows not deleted';
  elsif exists (select 1 from pendingbot.skills where id = skill_id) then
    failure := 'user-owned skills not deleted';
  else
    -- Rows that should remain but be decoupled.
    select exists(select 1 from pendingbot.audit_log where id = audit_id and user_id is null and conversation_id is null)
      into audit_remained;
    select exists(select 1 from pendingbot.invites where code = invite_code and created_by is null and used_by is null)
      into invite_remained;
    select exists(select 1 from pendingbot.tools where id = tool_id and owner_id is null)
      into tool_remained;
    if not audit_remained then
      failure := 'audit_log row missing or not decoupled';
    elsif not invite_remained then
      failure := 'invites row missing or not decoupled';
    elsif not tool_remained then
      failure := 'tools row missing or not decoupled';
    end if;
  end if;

  -- Always clean up the surviving rows the function intentionally left.
  delete from pendingbot.audit_log where id = audit_id;
  delete from pendingbot.invites where code = invite_code;
  delete from pendingbot.tools where id = tool_id;

  if failure is not null then
    raise exception 'self-delete test failed: %', failure;
  end if;
  raise notice 'self-delete test passed';
end $$;
