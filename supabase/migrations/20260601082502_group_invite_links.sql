-- Group invite-link model (decisions.md D2) — per-inviter, attributable.
--
-- Mirrors the bot invite-link model (D1, migration 20260601074455). The shared
-- single group code (group_join_handles) is superseded by per-inviter tokens:
-- every member mints their own reusable link to the same group, so we record
-- who pulled each new member in (invited_by). Whoever holds a link joins THAT
-- group; each person's link is distinct.
--
-- RLS not loosened: group_invite_links is service-role-only; all access via the
-- SECURITY DEFINER RPCs below. The old group_join_handles flow stays until iOS
-- reworks to tokens (then it can be removed).

BEGIN;

-- 1. Attribution columns: who invited each member / requester.
ALTER TABLE pendingbot.conversation_participants
  ADD COLUMN IF NOT EXISTS invited_by uuid
    REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.group_join_requests
  ADD COLUMN IF NOT EXISTS invited_by uuid
    REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2. The per-inviter invite-link table.
CREATE TABLE IF NOT EXISTS pendingbot.group_invite_links (
  token           text        PRIMARY KEY,
  conversation_id uuid        NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  inviter_user_id uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL DEFAULT (now() + interval '7 days'),
  revoked_at      timestamptz
);

CREATE INDEX IF NOT EXISTS group_invite_links_conv_idx
  ON pendingbot.group_invite_links (conversation_id);
CREATE INDEX IF NOT EXISTS group_invite_links_inviter_idx
  ON pendingbot.group_invite_links (inviter_user_id, conversation_id);

ALTER TABLE pendingbot.group_invite_links OWNER TO postgres;
ALTER TABLE pendingbot.group_invite_links ENABLE ROW LEVEL SECURITY;

-- 3a. Mint a link. Caller (auth.uid) must already be a member of the group.
CREATE OR REPLACE FUNCTION pendingbot.group_invite_link_create(p_conversation_id uuid)
RETURNS TABLE (token text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  v_token   text;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  if not exists (
    select 1 from pendingbot.conversation_participants
     where conversation_id = p_conversation_id
       and participant_type = 'user' and participant_id = caller_id
  ) then
    raise exception '只有群成员才能邀请别人';
  end if;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');

  insert into pendingbot.group_invite_links (token, conversation_id, inviter_user_id)
  values (v_token, p_conversation_id, caller_id);

  return query
    select gil.token, gil.expires_at
      from pendingbot.group_invite_links gil
     where gil.token = v_token;
end $$;
ALTER FUNCTION pendingbot.group_invite_link_create(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_link_create(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_link_create(uuid) TO authenticated;

-- 3b. List the caller's own active links for a group (management UI).
CREATE OR REPLACE FUNCTION pendingbot.group_invite_links_list(p_conversation_id uuid)
RETURNS TABLE (token text, created_at timestamptz, expires_at timestamptz, revoked_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare caller_id uuid := auth.uid();
begin
  if caller_id is null then raise exception 'auth required'; end if;
  return query
    select gil.token, gil.created_at, gil.expires_at, gil.revoked_at
      from pendingbot.group_invite_links gil
     where gil.conversation_id = p_conversation_id and gil.inviter_user_id = caller_id
     order by gil.created_at desc;
end $$;
ALTER FUNCTION pendingbot.group_invite_links_list(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_links_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_links_list(uuid) TO authenticated;

-- 3c. Revoke a link. Only the inviter who minted it, or a group owner/admin.
CREATE OR REPLACE FUNCTION pendingbot.group_invite_link_revoke(p_token text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  link_row  record;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  select gil.conversation_id, gil.inviter_user_id into link_row
    from pendingbot.group_invite_links gil where gil.token = p_token;
  if link_row is null then raise exception '链接不存在'; end if;

  if link_row.inviter_user_id <> caller_id
     and not exists (
       select 1 from pendingbot.conversation_participants
        where conversation_id = link_row.conversation_id
          and participant_type = 'user' and participant_id = caller_id
          and role in ('owner', 'admin')
     ) then
    raise exception '只有签发者或群管理员能撤销';
  end if;

  update pendingbot.group_invite_links
     set revoked_at = now()
   where token = p_token and revoked_at is null;
end $$;
ALTER FUNCTION pendingbot.group_invite_link_revoke(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_link_revoke(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_link_revoke(text) TO authenticated;

-- 3d. Resolve a token to a group preview (join confirmation page).
CREATE OR REPLACE FUNCTION pendingbot.group_invite_link_resolve(p_token text)
RETURNS TABLE (
  conversation_id uuid,
  title           text,
  member_count    int,
  join_policy     text,
  inviter_name    text
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  link_row  record;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  select gil.conversation_id, gil.inviter_user_id, gil.expires_at, gil.revoked_at
    into link_row
    from pendingbot.group_invite_links gil where gil.token = p_token;
  if link_row is null then raise exception '邀请链接无效'; end if;
  if link_row.revoked_at is not null then raise exception '邀请链接已撤销'; end if;
  if link_row.expires_at < now() then raise exception '邀请链接已过期'; end if;

  return query
    select gm.conversation_id,
           gm.title,
           pendingbot._group_member_count(gm.conversation_id),
           gm.join_policy::text,
           u.display_name
      from pendingbot.conversation_group_meta gm
      join pendingbot.users u on u.id = link_row.inviter_user_id
     where gm.conversation_id = link_row.conversation_id;
end $$;
ALTER FUNCTION pendingbot.group_invite_link_resolve(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_link_resolve(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_link_resolve(text) TO authenticated;

-- 3e. Redeem a token: join (scan_open) or file a join request (approval),
--     recording invited_by. Mirrors group_join_request_create but token-based.
CREATE OR REPLACE FUNCTION pendingbot.group_invite_link_redeem(p_token text, p_message text)
RETURNS TABLE (conversation_id uuid, request_id uuid, joined boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
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

    insert into pendingbot.group_member_billing (conversation_id, user_id)
    values (link_row.conversation_id, caller_id)
    on conflict (conversation_id, user_id) do update set participates = true;

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
end $$;
ALTER FUNCTION pendingbot.group_invite_link_redeem(text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_invite_link_redeem(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_invite_link_redeem(text, text) TO authenticated;

-- 4. Propagate invited_by from the join request onto the membership row when
--    an approval-policy request is approved. Re-create with the same signature.
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
      (conversation_id, participant_type, participant_id, role, invited_by)
    values
      (req.conversation_id, 'user', req.requester_id, 'member', req.invited_by)
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

COMMIT;
