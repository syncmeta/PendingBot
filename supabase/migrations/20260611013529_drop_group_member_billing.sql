-- #226 physical-drop tail: retire pendingbot.group_member_billing.
--
-- The per-conversation cost-split model is fully retired (group spend now
-- settles through the group wallet: billing/group-wallet.ts + WalletDO).
-- group_member_billing kept existing only because a batch of live SECURITY
-- DEFINER RPCs still wrote to it. This migration rewrites those RPCs to drop
-- the dead-table statements, then drops the table.
--
-- State audit before this migration (live pg_get_functiondef, 2026-06-11):
--   * subject_wallets — already gone from live; zero remaining references.
--   * group_member_billing writers: open_group_conv / bootstrap_user_id /
--     group_invite_user / group_invite_link_redeem / group_join_request_create
--     / group_join_request_decide / group_remove_member / group_set_member_mute.
--   * `muted` is double-written to conversation_participants.muted since 0045;
--     that mirror is the surviving source of truth — nothing changes for
--     readers of participant rows (APNs fan-out etc.).
--   * `overdrawn`/`frozen_at` (per-member freeze) lost their only writer when
--     apply_audit_split was dropped with billing-v2 — dead state. The freeze
--     trigger function goes away with the table; iOS freeze UI is removed in
--     the same change set.
--   * No FKs into the table, no views, no policies on other tables reference it.
--
-- P0 fixed in passing: live open_group_conv still INSERTed into
-- group_billing_config — a table dropped in 20260603112148 — so POST
-- /v1/groups (create group) failed with 42P01 since 2026-06-03. The rewrite
-- below removes that statement (same root cause as the bootstrap_user_id fix
-- in 20260604085445, which missed this function).

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- 1. open_group_conv — drop group_billing_config (P0) + gmb seeding
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.open_group_conv(p_title text, p_initial_user_ids uuid[], p_initial_bot_ids uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
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

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner');

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
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 2. bootstrap_user_id — drop gmb seeding for preset groups
-- ─────────────────────────────────────────────────────────────────────

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

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner');

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

-- ─────────────────────────────────────────────────────────────────────
-- 3. group_invite_user — drop gmb seeding
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_invite_user(p_conv_id uuid, p_target_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
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
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 4. group_invite_link_redeem — drop gmb seeding (scan_open branch)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_invite_link_redeem(p_token text, p_message text)
 RETURNS TABLE(conversation_id uuid, request_id uuid, joined boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  link_row  pendingbot.group_invite_links%rowtype;
  meta_row  pendingbot.conversation_group_meta%rowtype;
  req_id    uuid;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  select * into link_row from pendingbot.group_invite_links where token = p_token;
  if link_row.token is null then raise exception '邀请链接无效'; end if;
  if link_row.revoked_at is not null then raise exception '邀请链接已撤销'; end if;
  if link_row.expires_at < now() then raise exception '邀请链接已过期'; end if;

  -- Already a member?
  if exists (
    select 1 from pendingbot.conversation_participants
     where conversation_participants.conversation_id = link_row.conversation_id
       and participant_type = 'user' and participant_id = caller_id
  ) then
    return query select link_row.conversation_id, null::uuid, false;
    return;
  end if;

  select * into meta_row from pendingbot.conversation_group_meta
   where conversation_group_meta.conversation_id = link_row.conversation_id;
  if meta_row.conversation_id is null then raise exception 'group meta not found'; end if;
  if meta_row.join_policy = 'closed' then raise exception 'group is closed to new members'; end if;
  if pendingbot._group_member_count(link_row.conversation_id) >= meta_row.max_members then
    raise exception 'group is full';
  end if;

  if meta_row.join_policy = 'scan_open' then
    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role, invited_by)
    values
      (link_row.conversation_id, 'user', caller_id, 'member', link_row.inviter_user_id)
    on conflict do nothing;

    return query select link_row.conversation_id, null::uuid, true;
    return;
  end if;

  -- 'approval' branch — file a request carrying invited_by (propagated to the
  -- membership row on approval by group_join_request_decide).
  insert into pendingbot.group_join_requests
    (conversation_id, requester_id, via_handle_id, message, invited_by)
  values
    (link_row.conversation_id, caller_id, null, nullif(trim(p_message), ''), link_row.inviter_user_id)
  on conflict (conversation_id, requester_id) where status = 'pending'
    do nothing
  returning id into req_id;

  if req_id is null then
    select id into req_id from pendingbot.group_join_requests
     where conversation_id = link_row.conversation_id
       and requester_id = caller_id and status = 'pending'
     limit 1;
  end if;

  return query select link_row.conversation_id, req_id, false;
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 5. group_join_request_create — drop gmb seeding (scan_open branch)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_join_request_create(p_handle_value text, p_message text)
 RETURNS TABLE(conversation_id uuid, request_id uuid, joined boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
#variable_conflict use_column
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
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 6. group_join_request_decide — drop gmb seeding (approve branch)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_join_request_decide(p_request_id uuid, p_approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
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
      (conversation_id, participant_type, participant_id, role, invited_by)
    values
      (req.conversation_id, 'user', req.requester_id, 'member', req.invited_by)
    on conflict do nothing;

    update pendingbot.group_join_requests
       set status = 'approved', decided_by = caller_id, decided_at = now()
     where id = p_request_id;
  else
    update pendingbot.group_join_requests
       set status = 'rejected', decided_by = caller_id, decided_at = now()
     where id = p_request_id;
  end if;
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 7. group_remove_member — drop gmb "audit history" update
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_remove_member(p_conv_id uuid, p_target_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
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
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 8. group_set_member_mute — conversation_participants is now the only
--    store for the mute bit (it was already mirrored there since 0045)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_mute(p_conv_id uuid, p_muted boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public', 'auth'
AS $function$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin','member','observer']);

  update pendingbot.conversation_participants
     set muted = p_muted
   where conversation_id = p_conv_id
     and participant_type = 'user'
     and participant_id = caller_id;
end $function$;

-- ─────────────────────────────────────────────────────────────────────
-- 9. Drop the table (trigger + RLS policies go with it) and the now-
--    orphaned freeze trigger function.
-- ─────────────────────────────────────────────────────────────────────

DROP TABLE IF EXISTS pendingbot.group_member_billing;
DROP FUNCTION IF EXISTS pendingbot._group_member_billing_freeze_trigger();

-- ─────────────────────────────────────────────────────────────────────
-- 10. group_member_invitations: drop the per-invite billing snapshot
--     columns from the retired split model. The invite card's hint text
--     is synthesized at read time by the edge route now (it has been a
--     constant since the split model was unplugged), so persisting it
--     per row was pure dead weight.
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.group_member_invitations
  DROP COLUMN IF EXISTS billing_snapshot,
  DROP COLUMN IF EXISTS invitee_participates;

COMMIT;
