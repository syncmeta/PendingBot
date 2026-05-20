-- 20260520152815_fix_group_join_request_create_ambiguity
--
-- Bug: `pendingbot.group_join_request_create` returns
--   RETURNS table(conversation_id uuid, request_id uuid, joined boolean)
-- which makes `conversation_id` an implicit plpgsql variable in the
-- function body. The INSERT statements use bare `conversation_id` in
-- the column list / ON CONFLICT target, and Postgres' default
-- variable_conflict = error rule rejects every call with
--   42702 column reference "conversation_id" is ambiguous
-- the moment the function reaches the INSERT into group_join_requests
-- (the approval branch) or group_member_billing (the scan_open branch).
--
-- Result: nobody can join an existing group, neither by number nor QR.
-- The bug has been there since 0045 but only surfaced now that iOS
-- actually exercises the join flow.
--
-- Minimal fix: add `#variable_conflict use_column` at the top of the
-- body so bare `conversation_id` resolves to the column, not the OUT
-- param. The function still RETURNS the same TABLE shape — the OUT
-- columns are populated positionally by RETURN QUERY, and all the
-- bodies that read `handle_row.conversation_id` keep their qualifier
-- so nothing else changes. RPC contract (`{ conversation_id, request_id,
-- joined }`) is preserved verbatim.

CREATE OR REPLACE FUNCTION pendingbot.group_join_request_create(
  p_handle_value text,
  p_message text
) RETURNS table(conversation_id uuid, request_id uuid, joined boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
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
