-- Group member cap: 100 → 30 (humans + bots combined).
-- Per user request — small enough that the small-model router stays
-- cheap, and large enough to fit a real working group.
--
-- Three places to keep in sync:
--   1. conversation_group_meta.max_members CHECK + DEFAULT
--   2. existing rows clamped down (UPDATE)
--   3. the four RPCs that read / enforce the cap

BEGIN;

-- 1. Clamp existing rows. No-op until groups get created in prod, but
--    keeps this migration idempotent and avoids a surprise if someone
--    seeded a group between deploy waves.
UPDATE pendingbot.conversation_group_meta
   SET max_members = LEAST(max_members, 30)
 WHERE max_members > 30;

-- 2. Swap the CHECK constraint and the column default.
ALTER TABLE pendingbot.conversation_group_meta
  DROP CONSTRAINT IF EXISTS conversation_group_meta_max_members_chk;

ALTER TABLE pendingbot.conversation_group_meta
  ADD CONSTRAINT conversation_group_meta_max_members_chk
    CHECK (max_members > 0 AND max_members <= 30);

ALTER TABLE pendingbot.conversation_group_meta
  ALTER COLUMN max_members SET DEFAULT 30;

-- 3. Replace the four RPC bodies that hard-code 100. Same signatures;
--    only the cap literal changes. Re-running these CREATE OR REPLACE
--    on later renumbers is harmless.

-- 3a. open_group_conv: pre-flight cap check at creation.
CREATE OR REPLACE FUNCTION pendingbot.open_group_conv(
  p_title text,
  p_initial_user_ids uuid[],
  p_initial_bot_ids uuid[]
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  conv_id uuid;
  uid uuid;
  bid uuid;
  bot_visibility text;
  bot_creator uuid;
  total_count int;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  -- Cap members at 30 (humans + bots combined). Caller + N humans + M bots.
  total_count := 1
                + coalesce(array_length(p_initial_user_ids, 1), 0)
                + coalesce(array_length(p_initial_bot_ids, 1), 0);
  if total_count > 30 then
    raise exception 'group cannot exceed 30 members on creation';
  end if;

  -- Up-front bot validation: refuse private bots, gate public_invite.
  if p_initial_bot_ids is not null then
    foreach bid in array p_initial_bot_ids loop
      select visibility, creator_id into bot_visibility, bot_creator
        from pendingbot.bots
       where id = bid and is_active = true;
      if bot_visibility is null then
        raise exception 'bot % not found or inactive', bid;
      end if;
      if bot_visibility = 'private' then
        raise exception 'private bots cannot be added to a group';
      end if;
      if bot_visibility = 'public_invite'
         and (bot_creator is null or bot_creator <> caller_id) then
        if not exists (
          select 1 from pendingbot.bot_invites
           where bot_id = bid and user_id = caller_id
        ) then
          raise exception 'caller not invited to bot %', bid;
        end if;
      end if;
    end loop;
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('group', 'message', caller_id, null, nullif(trim(p_title), ''))
  returning id into conv_id;

  insert into pendingbot.conversation_group_meta
    (conversation_id, title, created_by)
  values
    (conv_id, nullif(trim(p_title), ''), caller_id);

  insert into pendingbot.group_billing_config (conversation_id, updated_by)
  values (conv_id, caller_id);

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner');

  insert into pendingbot.group_member_billing (conversation_id, user_id)
  values (conv_id, caller_id);

  if p_initial_user_ids is not null then
    foreach uid in array p_initial_user_ids loop
      if uid = caller_id then
        continue;
      end if;
      insert into pendingbot.conversation_participants
        (conversation_id, participant_type, participant_id, role)
      values
        (conv_id, 'user', uid, 'member')
      on conflict do nothing;
      insert into pendingbot.group_member_billing (conversation_id, user_id)
      values (conv_id, uid)
      on conflict do nothing;
    end loop;
  end if;

  if p_initial_bot_ids is not null then
    foreach bid in array p_initial_bot_ids loop
      insert into pendingbot.conversation_participants
        (conversation_id, participant_type, participant_id, role)
      values
        (conv_id, 'bot', bid, 'member')
      on conflict do nothing;
    end loop;
  end if;

  return conv_id;
end $$;

-- 3b. group_invite_user: post-creation cap check.
CREATE OR REPLACE FUNCTION pendingbot.group_invite_user(
  p_conv_id uuid,
  p_target_user_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  max_n int;
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  if not exists (select 1 from auth.users where id = p_target_user_id) then
    raise exception 'user not found';
  end if;

  select max_members into max_n
    from pendingbot.conversation_group_meta
   where conversation_id = p_conv_id;
  if pendingbot._group_member_count(p_conv_id) >= coalesce(max_n, 30) then
    raise exception 'group is full';
  end if;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (p_conv_id, 'user', p_target_user_id, 'member')
  on conflict do nothing;

  insert into pendingbot.group_member_billing (conversation_id, user_id)
  values (p_conv_id, p_target_user_id)
  on conflict do nothing;
end $$;

-- 3c. group_invite_bot: same cap check.
CREATE OR REPLACE FUNCTION pendingbot.group_invite_bot(
  p_conv_id uuid,
  p_bot_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  bot_visibility text;
  bot_creator uuid;
  bot_active boolean;
  max_n int;
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  select visibility, creator_id, is_active
    into bot_visibility, bot_creator, bot_active
    from pendingbot.bots
   where id = p_bot_id;
  if bot_visibility is null then
    raise exception 'bot not found';
  end if;
  if not coalesce(bot_active, false) then
    raise exception 'bot is inactive';
  end if;
  if bot_visibility = 'private' then
    raise exception 'private bots cannot be added to a group';
  end if;
  if bot_visibility = 'public_invite'
     and (bot_creator is null or bot_creator <> caller_id) then
    if not exists (
      select 1 from pendingbot.bot_invites
       where bot_id = p_bot_id and user_id = caller_id
    ) then
      raise exception 'caller not invited to bot %', p_bot_id;
    end if;
  end if;

  select max_members into max_n
    from pendingbot.conversation_group_meta
   where conversation_id = p_conv_id;
  if pendingbot._group_member_count(p_conv_id) >= coalesce(max_n, 30) then
    raise exception 'group is full';
  end if;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (p_conv_id, 'bot', p_bot_id, 'member')
  on conflict do nothing;
end $$;

-- 3d. group_join_request_decide: cap check on approval branch.
CREATE OR REPLACE FUNCTION pendingbot.group_join_request_decide(
  p_request_id uuid,
  p_approve boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  req pendingbot.group_join_requests%rowtype;
  max_n int;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select * into req
    from pendingbot.group_join_requests
   where id = p_request_id;
  if req.id is null then
    raise exception 'request not found';
  end if;
  if req.status <> 'pending' then
    raise exception 'request already decided';
  end if;

  perform pendingbot._assert_group_role(req.conversation_id, array['owner','admin']);

  if p_approve then
    select max_members into max_n
      from pendingbot.conversation_group_meta
     where conversation_group_meta.conversation_id = req.conversation_id;
    if pendingbot._group_member_count(req.conversation_id) >= coalesce(max_n, 30) then
      raise exception 'group is full';
    end if;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (req.conversation_id, 'user', req.requester_id, 'member')
    on conflict do nothing;

    insert into pendingbot.group_member_billing (conversation_id, user_id)
    values (req.conversation_id, req.requester_id)
    on conflict (conversation_id, user_id) do update
      set participates = true;

    update pendingbot.group_join_requests
       set status = 'approved', decided_by = caller_id, decided_at = now()
     where id = p_request_id;
  else
    update pendingbot.group_join_requests
       set status = 'rejected', decided_by = caller_id, decided_at = now()
     where id = p_request_id;
  end if;
end $$;

COMMIT;
