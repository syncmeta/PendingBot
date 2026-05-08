-- Group chat — RPC layer.
-- All functions are SECURITY DEFINER + REVOKE ALL FROM PUBLIC + GRANT
-- EXECUTE TO authenticated (or service_role for worker-only entries).
-- Each RPC validates auth + role explicitly; we never rely on RLS to
-- gate writes here, since SECURITY DEFINER bypasses it.
--
-- Tables created in 0043. The shared invariant on every "write to a
-- group" RPC is:
--
--   1) `auth.uid()` is non-null
--   2) caller is a participant of `conv_id` with the right role
--   3) the conversation is `conversation_type='group'`
--
-- We hoist (1)-(3) into a helper, `_assert_group_role(conv_id, roles)`,
-- to keep the RPC bodies readable.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot._assert_group_role(
  p_conv_id uuid,
  p_allowed_roles text[]
) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  caller_role text;
  conv_kind text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select conversation_type into conv_kind
    from pendingbot.conversations
   where id = p_conv_id;
  if conv_kind is null then
    raise exception 'conversation not found';
  end if;
  if conv_kind <> 'group' then
    raise exception 'not a group conversation';
  end if;

  select role into caller_role
    from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = caller_id;
  if caller_role is null then
    raise exception 'not a member';
  end if;
  if not (caller_role = any(p_allowed_roles)) then
    raise exception 'forbidden: requires role in %', p_allowed_roles;
  end if;
end $$;
ALTER FUNCTION pendingbot._assert_group_role(uuid, text[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._assert_group_role(uuid, text[]) FROM PUBLIC;

-- Count current member rows for a conversation (humans + bots).
CREATE OR REPLACE FUNCTION pendingbot._group_member_count(p_conv_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
  select count(*)::int
    from pendingbot.conversation_participants
   where conversation_id = p_conv_id;
$$;
ALTER FUNCTION pendingbot._group_member_count(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._group_member_count(uuid) FROM PUBLIC;

-- ─────────────────────────────────────────────────────────────────────
-- open_group_conv — create a group with initial humans and bots.
-- Caller becomes 'owner'. All initial humans become 'member'.
-- Bots: validates visibility != 'private'; for 'public_invite', the
-- caller must be in bot_invites or be the bot's creator.
-- ─────────────────────────────────────────────────────────────────────

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

  -- Cap members at the schema limit (100). Caller + N humans + M bots.
  total_count := 1
                + coalesce(array_length(p_initial_user_ids, 1), 0)
                + coalesce(array_length(p_initial_bot_ids, 1), 0);
  if total_count > 100 then
    raise exception 'group cannot exceed 100 members on creation';
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

  -- Create the conversation row. bot_id stays NULL — groups have no
  -- pinned bot; the small-model router decides per turn.
  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('group', 'message', caller_id, null, nullif(trim(p_title), ''))
  returning id into conv_id;

  -- Sidecar metadata.
  insert into pendingbot.conversation_group_meta
    (conversation_id, title, created_by)
  values
    (conv_id, nullif(trim(p_title), ''), caller_id);

  -- Default billing config (hybrid 50/50, 24h window).
  insert into pendingbot.group_billing_config (conversation_id, updated_by)
  values (conv_id, caller_id);

  -- Caller as owner.
  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner');

  insert into pendingbot.group_member_billing (conversation_id, user_id)
  values (conv_id, caller_id);

  -- Initial humans.
  if p_initial_user_ids is not null then
    foreach uid in array p_initial_user_ids loop
      if uid = caller_id then
        continue;  -- already inserted as owner
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

  -- Initial bots.
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
ALTER FUNCTION pendingbot.open_group_conv(text, uuid[], uuid[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.open_group_conv(text, uuid[], uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.open_group_conv(text, uuid[], uuid[]) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_invite_user — owner/admin adds a human directly (no approval).
-- ─────────────────────────────────────────────────────────────────────

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
  if pendingbot._group_member_count(p_conv_id) >= coalesce(max_n, 100) then
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
ALTER FUNCTION pendingbot.group_invite_user(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_user(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_user(uuid, uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_invite_bot — owner/admin pulls a bot in. Visibility gated.
-- The first description for this (group, bot) pair is generated by the
-- worker AFTER this RPC succeeds; the LLM call is billed to the group.
-- ─────────────────────────────────────────────────────────────────────

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
  if pendingbot._group_member_count(p_conv_id) >= coalesce(max_n, 100) then
    raise exception 'group is full';
  end if;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (p_conv_id, 'bot', p_bot_id, 'member')
  on conflict do nothing;
end $$;
ALTER FUNCTION pendingbot.group_invite_bot(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_bot(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_bot(uuid, uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_remove_member — owner/admin kicks anyone except the owner.
-- Self can call to leave (any role except owner; owner has to transfer
-- ownership first — out of v1 scope, owner cannot leave their own
-- group).
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_remove_member(
  p_conv_id uuid,
  p_target_user_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  caller_role text;
  target_role text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select role into caller_role
    from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = caller_id;
  if caller_role is null then
    raise exception 'not a member';
  end if;

  select role into target_role
    from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = p_target_user_id;
  if target_role is null then
    return;  -- already gone, idempotent
  end if;

  -- Self-leave is OK unless caller is owner.
  if caller_id = p_target_user_id then
    if caller_role = 'owner' then
      raise exception 'owner cannot leave; transfer ownership first';
    end if;
  else
    -- Removing someone else: must be owner/admin, and target can't be owner.
    if not (caller_role in ('owner','admin')) then
      raise exception 'forbidden';
    end if;
    if target_role = 'owner' then
      raise exception 'cannot remove the owner';
    end if;
  end if;

  delete from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = p_target_user_id;
  -- Keep group_member_billing rows for audit history; mark inactive
  -- by setting participates=false. (Plain DELETE would lose the
  -- spent_credits running total.)
  update pendingbot.group_member_billing
     set participates = false
   where conversation_id = p_conv_id and user_id = p_target_user_id;
end $$;
ALTER FUNCTION pendingbot.group_remove_member(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_remove_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_remove_member(uuid, uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_remove_bot — owner/admin only.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_remove_bot(
  p_conv_id uuid,
  p_bot_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  delete from pendingbot.conversation_participants
   where conversation_id = p_conv_id
     and participant_type = 'bot'
     and participant_id = p_bot_id;
  -- Keep group_bot_descriptions for history; harmless if bot rejoins.
end $$;
ALTER FUNCTION pendingbot.group_remove_bot(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_remove_bot(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_remove_bot(uuid, uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_member_role — owner only. Promote member→admin or demote.
-- Cannot transfer 'owner' (out of v1 scope).
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_role(
  p_conv_id uuid,
  p_target_user_id uuid,
  p_role text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner']);

  if not (p_role in ('admin','member')) then
    raise exception 'role must be admin or member';
  end if;

  update pendingbot.conversation_participants
     set role = p_role
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = p_target_user_id
     and role <> 'owner';  -- never overwrite the owner row
end $$;
ALTER FUNCTION pendingbot.group_set_member_role(uuid, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_member_role(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_member_role(uuid, uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_member_nickname — caller sets their own nickname.
-- Empty string clears it. Uniqueness enforced by partial index.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_nickname(
  p_conv_id uuid,
  p_nickname text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  cleaned text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin','member','observer']);

  cleaned := nullif(trim(p_nickname), '');
  if cleaned is not null and char_length(cleaned) > 32 then
    raise exception 'nickname too long (max 32 chars)';
  end if;

  update pendingbot.conversation_participants
     set nickname = cleaned
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = caller_id;
end $$;
ALTER FUNCTION pendingbot.group_set_member_nickname(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_member_nickname(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_member_nickname(uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_bot_nickname — set nickname for a bot in this group.
-- Designed for the worker to call on the bot's behalf when a bot uses
-- its set_my_group_nickname tool. authenticated callers can also use
-- it if they are owner/admin (manual override).
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_bot_nickname(
  p_conv_id uuid,
  p_bot_id uuid,
  p_nickname text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  cleaned text;
begin
  -- service_role (worker) calls bypass auth.uid() check; for client
  -- callers we require owner/admin.
  if caller_id is not null then
    perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);
  end if;

  if not exists (
    select 1 from pendingbot.conversation_participants
     where conversation_id = p_conv_id
       and participant_type = 'bot'
       and participant_id = p_bot_id
  ) then
    raise exception 'bot is not a member of the group';
  end if;

  cleaned := nullif(trim(p_nickname), '');
  if cleaned is not null and char_length(cleaned) > 32 then
    raise exception 'nickname too long (max 32 chars)';
  end if;

  update pendingbot.conversation_participants
     set nickname = cleaned
   where conversation_id = p_conv_id
     and participant_type = 'bot'
     and participant_id = p_bot_id;
end $$;
ALTER FUNCTION pendingbot.group_set_bot_nickname(uuid, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_bot_nickname(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_bot_nickname(uuid, uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_bot_description — bot's "call me when…" doc, per-group.
-- Worker calls via service_role for the bot; owner/admin can manually
-- edit too. revision_count auto-increments on update.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_bot_description(
  p_conv_id uuid,
  p_bot_id uuid,
  p_description text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  cleaned text;
begin
  if caller_id is not null then
    perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);
  end if;

  cleaned := nullif(trim(p_description), '');
  if cleaned is null then
    raise exception 'description must not be empty';
  end if;
  if char_length(cleaned) > 4000 then
    raise exception 'description too long (max 4000 chars)';
  end if;

  insert into pendingbot.group_bot_descriptions
    (conversation_id, bot_id, description, revision_count, updated_at)
  values
    (p_conv_id, p_bot_id, cleaned, 0, now())
  on conflict (conversation_id, bot_id) do update
    set description    = excluded.description,
        revision_count = pendingbot.group_bot_descriptions.revision_count + 1,
        updated_at     = now();
end $$;
ALTER FUNCTION pendingbot.group_set_bot_description(uuid, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_bot_description(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_bot_description(uuid, uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_billing — owner/admin replaces mode + window + (optional)
-- custom shares atomically. p_custom_shares is a jsonb array of
-- {user_id, weight_bps}; sum must be 10000 when mode='custom'.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_billing(
  p_conv_id uuid,
  p_mode text,
  p_window_seconds integer,
  p_custom_shares jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  share_record jsonb;
  total_bps int := 0;
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  if not (p_mode in ('custom','per_head','per_message','per_token','hybrid')) then
    raise exception 'invalid mode';
  end if;
  if p_window_seconds <= 0 or p_window_seconds > 30 * 86400 then
    raise exception 'invalid window_seconds';
  end if;

  update pendingbot.group_billing_config
     set mode           = p_mode::pendingbot.group_split_mode,
         window_seconds = p_window_seconds,
         updated_by     = caller_id,
         updated_at     = now()
   where conversation_id = p_conv_id;

  if p_mode = 'custom' then
    if p_custom_shares is null
       or jsonb_typeof(p_custom_shares) <> 'array'
       or jsonb_array_length(p_custom_shares) = 0 then
      raise exception 'custom mode requires non-empty p_custom_shares';
    end if;

    for share_record in select * from jsonb_array_elements(p_custom_shares) loop
      total_bps := total_bps + (share_record->>'weight_bps')::int;
    end loop;
    if total_bps <> 10000 then
      raise exception 'custom shares must sum to 10000 bps (got %)', total_bps;
    end if;

    delete from pendingbot.group_billing_custom_shares
     where conversation_id = p_conv_id;

    insert into pendingbot.group_billing_custom_shares
      (conversation_id, user_id, weight_bps)
    select
      p_conv_id,
      (s->>'user_id')::uuid,
      (s->>'weight_bps')::int
    from jsonb_array_elements(p_custom_shares) s;
  end if;
end $$;
ALTER FUNCTION pendingbot.group_set_billing(uuid, text, integer, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_billing(uuid, text, integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_billing(uuid, text, integer, jsonb) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_member_cap — caller sets their own per-group PND cap.
-- NULL means no cap.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_cap(
  p_conv_id uuid,
  p_cap_credits bigint
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin','member','observer']);

  if p_cap_credits is not null and p_cap_credits < 0 then
    raise exception 'cap_credits must be >= 0';
  end if;

  update pendingbot.group_member_billing
     set cap_credits = p_cap_credits
   where conversation_id = p_conv_id and user_id = caller_id;
end $$;
ALTER FUNCTION pendingbot.group_set_member_cap(uuid, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_member_cap(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_member_cap(uuid, bigint) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_member_participates — owner/admin flips a member in/out
-- of cost sharing without removing them from the group.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_participates(
  p_conv_id uuid,
  p_target_user_id uuid,
  p_participates boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  update pendingbot.group_member_billing
     set participates = p_participates
   where conversation_id = p_conv_id and user_id = p_target_user_id;
end $$;
ALTER FUNCTION pendingbot.group_set_member_participates(uuid, uuid, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_member_participates(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_member_participates(uuid, uuid, boolean) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_member_mute — caller toggles their own mute.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_mute(
  p_conv_id uuid,
  p_muted boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin','member','observer']);

  update pendingbot.group_member_billing
     set muted = p_muted
   where conversation_id = p_conv_id and user_id = caller_id;
  -- Mirror onto conversation_participants too, for views that already
  -- read the participant row (e.g. APNs fan-out).
  update pendingbot.conversation_participants
     set muted = p_muted
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = caller_id;
end $$;
ALTER FUNCTION pendingbot.group_set_member_mute(uuid, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_member_mute(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_member_mute(uuid, boolean) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_handle — owner/admin sets the group's number / qr value.
-- Empty string disables the handle (deletes the row). Reuses the same
-- charset constraint as the table CHECK; uniqueness errors bubble up.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_handle(
  p_conv_id uuid,
  p_handle_type text,
  p_value text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  cleaned text;
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  if not (p_handle_type in ('number','qr')) then
    raise exception 'handle_type must be number or qr';
  end if;

  cleaned := nullif(trim(p_value), '');
  if cleaned is null then
    delete from pendingbot.group_join_handles
     where conversation_id = p_conv_id and handle_type = p_handle_type;
    return;
  end if;

  if cleaned !~ '^[A-Za-z0-9_-]{4,20}$' then
    raise exception 'handle must be 4-20 chars of [A-Za-z0-9_-]';
  end if;

  insert into pendingbot.group_join_handles
    (conversation_id, handle_type, value, enabled)
  values
    (p_conv_id, p_handle_type, cleaned, true)
  on conflict (conversation_id, handle_type) do update
    set value = excluded.value, enabled = true;
end $$;
ALTER FUNCTION pendingbot.group_set_handle(uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_handle(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_handle(uuid, text, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_set_join_policy — owner/admin sets the join_policy enum.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_join_policy(
  p_conv_id uuid,
  p_policy text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
begin
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin']);

  if not (p_policy in ('scan_open','approval','closed')) then
    raise exception 'invalid join policy';
  end if;

  update pendingbot.conversation_group_meta
     set join_policy = p_policy::pendingbot.group_join_policy,
         updated_at  = now()
   where conversation_id = p_conv_id;
end $$;
ALTER FUNCTION pendingbot.group_set_join_policy(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_join_policy(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_join_policy(uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_join_request_create — caller looks up a group by handle value
-- and either joins immediately ('scan_open'), files a pending request
-- ('approval'), or is rejected ('closed').
-- Returns the conversation_id when joined directly, NULL for pending.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_join_request_create(
  p_handle_value text,
  p_message text
) RETURNS table(conversation_id uuid, request_id uuid, joined boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  handle_row pendingbot.group_join_handles%rowtype;
  meta_row pendingbot.conversation_group_meta%rowtype;
  req_id uuid;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select * into handle_row
    from pendingbot.group_join_handles
   where value = p_handle_value and enabled = true
   limit 1;
  if handle_row.id is null then
    raise exception 'group not found';
  end if;

  -- Already a member?
  if exists (
    select 1 from pendingbot.conversation_participants
     where conversation_participants.conversation_id = handle_row.conversation_id
       and participant_type = 'user'
       and participant_id = caller_id
  ) then
    return query select handle_row.conversation_id, null::uuid, false;
    return;
  end if;

  select * into meta_row
    from pendingbot.conversation_group_meta
   where conversation_group_meta.conversation_id = handle_row.conversation_id;
  if meta_row.conversation_id is null then
    raise exception 'group meta not found';
  end if;

  if meta_row.join_policy = 'closed' then
    raise exception 'group is closed to new members';
  end if;

  if pendingbot._group_member_count(handle_row.conversation_id) >= meta_row.max_members then
    raise exception 'group is full';
  end if;

  if meta_row.join_policy = 'scan_open' then
    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (handle_row.conversation_id, 'user', caller_id, 'member')
    on conflict do nothing;

    insert into pendingbot.group_member_billing (conversation_id, user_id)
    values (handle_row.conversation_id, caller_id)
    on conflict (conversation_id, user_id) do update
      set participates = true;

    return query select handle_row.conversation_id, null::uuid, true;
    return;
  end if;

  -- 'approval' branch — file a request, idempotent on the partial
  -- unique index (one pending row per (group, user)).
  insert into pendingbot.group_join_requests
    (conversation_id, requester_id, via_handle_id, message)
  values
    (handle_row.conversation_id, caller_id, handle_row.id, nullif(trim(p_message), ''))
  on conflict (conversation_id, requester_id) where status = 'pending'
    do nothing
  returning id into req_id;

  if req_id is null then
    select id into req_id from pendingbot.group_join_requests
     where group_join_requests.conversation_id = handle_row.conversation_id
       and requester_id = caller_id
       and status = 'pending'
     limit 1;
  end if;

  return query select handle_row.conversation_id, req_id, false;
end $$;
ALTER FUNCTION pendingbot.group_join_request_create(text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_join_request_create(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_join_request_create(text, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_join_request_decide — owner/admin approves or rejects.
-- ─────────────────────────────────────────────────────────────────────

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
    if pendingbot._group_member_count(req.conversation_id) >= coalesce(max_n, 100) then
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
ALTER FUNCTION pendingbot.group_join_request_decide(uuid, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_join_request_decide(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_join_request_decide(uuid, boolean) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- group_continue_decide — any human participant can decide.
-- The "decision message" is a normal user message inserted by the edge
-- before this RPC; this RPC only links it and stamps the decision.
-- Triggering the bot continuation itself is the worker's job (it polls
-- the row or is woken by the edge after this RPC succeeds).
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_continue_decide(
  p_request_id uuid,
  p_decision_message_id uuid,
  p_decision text
) RETURNS pendingbot.group_continue_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  req pendingbot.group_continue_requests%rowtype;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;
  if not (p_decision in ('allowed','denied')) then
    raise exception 'decision must be allowed or denied';
  end if;

  select * into req
    from pendingbot.group_continue_requests
   where id = p_request_id
   for update;
  if req.id is null then
    raise exception 'request not found';
  end if;
  if req.status <> 'pending' then
    raise exception 'request already decided';
  end if;

  perform pendingbot._assert_group_role(req.conversation_id, array['owner','admin','member','observer']);

  update pendingbot.group_continue_requests
     set status              = p_decision::pendingbot.continue_request_status,
         decided_by          = caller_id,
         decided_at          = now(),
         decision_message_id = p_decision_message_id
   where id = p_request_id
   returning * into req;

  return req;
end $$;
ALTER FUNCTION pendingbot.group_continue_decide(uuid, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_continue_decide(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_continue_decide(uuid, uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- apply_audit_split — service_role only. Atomically writes split rows
-- + calls billing_debit per non-skipped user + bumps group_member_
-- billing.spent_credits. Input shape:
--   p_splits = [{user_id, share_bps, debited_credits, debit_status}]
-- Caller (worker, group-billing.ts) is responsible for computing the
-- split. This function is the single transactional commit.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.apply_audit_split(
  p_audit_log_id uuid,
  p_splits jsonb
) RETURNS void
LANGUAGE plpgsql
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  conv_id uuid;
  s jsonb;
  user_uuid uuid;
  share int;
  debited bigint;
  status_text text;
begin
  -- Read conv_id from the audit row so we don't trust the caller.
  select audit_log.conversation_id into conv_id
    from pendingbot.audit_log
   where audit_log.id = p_audit_log_id;
  if conv_id is null then
    raise exception 'audit_log row % not found', p_audit_log_id;
  end if;

  for s in select * from jsonb_array_elements(p_splits) loop
    user_uuid    := (s->>'user_id')::uuid;
    share        := coalesce((s->>'share_bps')::int, 0);
    debited      := coalesce((s->>'debited_credits')::bigint, 0);
    status_text  := coalesce(s->>'debit_status', 'debited');

    insert into pendingbot.audit_log_splits
      (audit_log_id, user_id, share_bps, debited_credits, debit_status)
    values
      (p_audit_log_id, user_uuid, share, debited, status_text)
    on conflict (audit_log_id, user_id) do update
      set share_bps       = excluded.share_bps,
          debited_credits = excluded.debited_credits,
          debit_status    = excluded.debit_status;

    if status_text = 'debited' and debited > 0 then
      perform pendingbot.billing_debit(user_uuid, p_audit_log_id, debited);
      update pendingbot.group_member_billing
         set spent_credits = spent_credits + debited,
             overdrawn = case
               when cap_credits is not null and (spent_credits + debited) >= cap_credits
                 then true
               else overdrawn
             end
       where conversation_id = conv_id and user_id = user_uuid;
    end if;
  end loop;
end $$;
ALTER FUNCTION pendingbot.apply_audit_split(uuid, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.apply_audit_split(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.apply_audit_split(uuid, jsonb) TO service_role;

COMMIT;
