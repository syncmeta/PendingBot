-- Bot invite-link model (decisions.md D1).
--
-- Bots are invite-only. The share artifact is NOT the bot's slug — it's a
-- reusable, inviter-scoped invite link (like a WeChat group QR / cloud-drive
-- share link): default 7-day expiry, revocable, attributable. Any *friend* of
-- the bot (a row in user_bot_contacts) — plus the creator — can mint a link.
-- Whoever holds it may join, and the join is recorded against the inviter.
--
-- RLS is NOT loosened: bot_invite_links is a service-role-only table; all
-- access goes through the SECURITY DEFINER RPCs below, which run as owner.
-- redeem() writes the bot_invites grant row itself, so the strict
-- bots_visible_read / user_bot_contacts_self_insert policies stay untouched.

BEGIN;

-- 1. Attribution column on the contact row: who pulled this user in.
ALTER TABLE pendingbot.user_bot_contacts
  ADD COLUMN IF NOT EXISTS invited_by uuid
    REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.user_bot_contacts
  DROP CONSTRAINT IF EXISTS user_bot_contacts_added_via_check;
ALTER TABLE pendingbot.user_bot_contacts
  ADD CONSTRAINT user_bot_contacts_added_via_check
    CHECK (added_via IN ('manual', 'bootstrap', 'auto_conv', 'backfill', 'invite_link'));

-- 2. The invite-link table.
CREATE TABLE IF NOT EXISTS pendingbot.bot_invite_links (
  token           text        PRIMARY KEY,
  bot_id          uuid        NOT NULL REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  inviter_user_id uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL DEFAULT (now() + interval '7 days'),
  revoked_at      timestamptz
);

CREATE INDEX IF NOT EXISTS bot_invite_links_bot_idx
  ON pendingbot.bot_invite_links (bot_id);
CREATE INDEX IF NOT EXISTS bot_invite_links_inviter_idx
  ON pendingbot.bot_invite_links (inviter_user_id, bot_id);

ALTER TABLE pendingbot.bot_invite_links OWNER TO postgres;
-- Service-role-only: RLS on, no permissive policy. Clients never touch this
-- table directly; they go through the definer RPCs below.
ALTER TABLE pendingbot.bot_invite_links ENABLE ROW LEVEL SECURITY;

-- 3a. Helper: is the caller allowed to mint/manage links for this bot?
--     creator OR an existing friend (user_bot_contacts row).
CREATE OR REPLACE FUNCTION pendingbot.bot_invite_caller_can_invite(
  p_bot_id uuid, p_user_id uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM pendingbot.bots b
     WHERE b.id = p_bot_id AND b.is_active = true
       AND (b.creator_id = p_user_id
            OR EXISTS (SELECT 1 FROM pendingbot.user_bot_contacts ubc
                        WHERE ubc.bot_id = p_bot_id AND ubc.user_id = p_user_id))
  );
$$;
ALTER FUNCTION pendingbot.bot_invite_caller_can_invite(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.bot_invite_caller_can_invite(uuid, uuid) FROM PUBLIC;

-- 3b. Mint a link. Caller (auth.uid) must be a friend or creator.
CREATE OR REPLACE FUNCTION pendingbot.bot_invite_link_create(p_bot_id uuid)
RETURNS TABLE (token text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  caller_id uuid := auth.uid();
  v_token   text;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  if not pendingbot.bot_invite_caller_can_invite(p_bot_id, caller_id) then
    raise exception '只有这个机器人的好友才能邀请别人';
  end if;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');

  insert into pendingbot.bot_invite_links (token, bot_id, inviter_user_id)
  values (v_token, p_bot_id, caller_id);

  return query
    select bil.token, bil.expires_at
      from pendingbot.bot_invite_links bil
     where bil.token = v_token;
end $$;
ALTER FUNCTION pendingbot.bot_invite_link_create(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.bot_invite_link_create(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.bot_invite_link_create(uuid) TO authenticated;

-- 3c. List the caller's own active links for a bot (management UI).
CREATE OR REPLACE FUNCTION pendingbot.bot_invite_links_list(p_bot_id uuid)
RETURNS TABLE (token text, created_at timestamptz, expires_at timestamptz, revoked_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare caller_id uuid := auth.uid();
begin
  if caller_id is null then raise exception 'auth required'; end if;
  return query
    select bil.token, bil.created_at, bil.expires_at, bil.revoked_at
      from pendingbot.bot_invite_links bil
     where bil.bot_id = p_bot_id and bil.inviter_user_id = caller_id
     order by bil.created_at desc;
end $$;
ALTER FUNCTION pendingbot.bot_invite_links_list(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.bot_invite_links_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.bot_invite_links_list(uuid) TO authenticated;

-- 3d. Revoke a link. Only the inviter who minted it, or the bot creator.
CREATE OR REPLACE FUNCTION pendingbot.bot_invite_link_revoke(p_token text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  caller_id uuid := auth.uid();
  link_row  record;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  select bil.bot_id, bil.inviter_user_id into link_row
    from pendingbot.bot_invite_links bil where bil.token = p_token;
  if link_row is null then raise exception '链接不存在'; end if;

  if link_row.inviter_user_id <> caller_id
     and not exists (select 1 from pendingbot.bots b
                      where b.id = link_row.bot_id and b.creator_id = caller_id) then
    raise exception '只有签发者或机器人创建者能撤销';
  end if;

  update pendingbot.bot_invite_links
     set revoked_at = now()
   where token = p_token and revoked_at is null;
end $$;
ALTER FUNCTION pendingbot.bot_invite_link_revoke(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.bot_invite_link_revoke(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.bot_invite_link_revoke(text) TO authenticated;

-- 3e. Resolve a token to a bot preview (for the "add bot" preview page).
--     Read-only; any authenticated holder of a valid token may preview.
CREATE OR REPLACE FUNCTION pendingbot.bot_invite_link_resolve(p_token text)
RETURNS TABLE (
  bot_id        uuid,
  display_name  text,
  slug          text,
  model_id      text,
  visibility    text,
  inviter_name  text
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  caller_id uuid := auth.uid();
  link_row  record;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  select bil.bot_id, bil.inviter_user_id, bil.expires_at, bil.revoked_at
    into link_row
    from pendingbot.bot_invite_links bil where bil.token = p_token;
  if link_row is null then raise exception '邀请链接无效'; end if;
  if link_row.revoked_at is not null then raise exception '邀请链接已撤销'; end if;
  if link_row.expires_at < now() then raise exception '邀请链接已过期'; end if;

  return query
    select b.id, b.display_name, b.slug, b.model_id, b.visibility,
           u.display_name
      from pendingbot.bots b
      join pendingbot.users u on u.id = link_row.inviter_user_id
     where b.id = link_row.bot_id and b.is_active = true;
end $$;
ALTER FUNCTION pendingbot.bot_invite_link_resolve(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.bot_invite_link_resolve(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.bot_invite_link_resolve(text) TO authenticated;

-- 3f. Redeem a token: grant the caller the bot + record attribution.
--     Writes bot_invites (satisfies bots_visible_read) and user_bot_contacts
--     (added_via='invite_link', invited_by=<minter>). Idempotent.
CREATE OR REPLACE FUNCTION pendingbot.bot_invite_link_redeem(p_token text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  caller_id uuid := auth.uid();
  link_row  record;
begin
  if caller_id is null then raise exception 'auth required'; end if;
  select bil.bot_id, bil.inviter_user_id, bil.expires_at, bil.revoked_at
    into link_row
    from pendingbot.bot_invite_links bil where bil.token = p_token;
  if link_row is null then raise exception '邀请链接无效'; end if;
  if link_row.revoked_at is not null then raise exception '邀请链接已撤销'; end if;
  if link_row.expires_at < now() then raise exception '邀请链接已过期'; end if;

  -- grant visibility (satisfies the existing invitee gate)
  insert into pendingbot.bot_invites (bot_id, user_id)
  values (link_row.bot_id, caller_id)
  on conflict (bot_id, user_id) do nothing;

  -- record the contact + who pulled them in (keep original on re-redeem)
  insert into pendingbot.user_bot_contacts (user_id, bot_id, added_via, invited_by)
  values (caller_id, link_row.bot_id, 'invite_link', link_row.inviter_user_id)
  on conflict (user_id, bot_id) do nothing;

  return link_row.bot_id;
end $$;
ALTER FUNCTION pendingbot.bot_invite_link_redeem(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.bot_invite_link_redeem(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.bot_invite_link_redeem(text) TO authenticated;

-- 4. Extend get_bot_friends to expose who invited each friend (D1 transparency).
--    Return-type change → drop + recreate.
DROP FUNCTION IF EXISTS pendingbot.get_bot_friends(uuid);

CREATE FUNCTION pendingbot.get_bot_friends(p_bot_id uuid)
RETURNS TABLE (
  user_id      uuid,
  display_name text,
  avatar_path  text,
  added_at     timestamptz,
  invited_by   uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  caller_id uuid := auth.uid();
  bot_row   record;
  allowed   boolean := false;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select id, creator_id, is_active into bot_row
    from pendingbot.bots where id = p_bot_id;

  if bot_row is null or bot_row.is_active = false then
    raise exception 'bot not found or inactive';
  end if;

  if bot_row.creator_id is not distinct from caller_id then
    allowed := true;
  end if;

  if not allowed and exists (
    select 1 from pendingbot.user_bot_contacts
     where bot_id = p_bot_id and user_id = caller_id
  ) then
    allowed := true;
  end if;

  if not allowed and exists (
    select 1
      from pendingbot.conversation_participants cp_user
      join pendingbot.conversation_participants cp_bot
        on cp_bot.conversation_id = cp_user.conversation_id
      join pendingbot.conversations c
        on c.id = cp_user.conversation_id
     where c.conversation_type = 'group'
       and cp_user.participant_type = 'user' and cp_user.participant_id = caller_id
       and cp_bot.participant_type  = 'bot'  and cp_bot.participant_id  = p_bot_id
  ) then
    allowed := true;
  end if;

  if not allowed then
    raise exception '没有权限查看此机器人的好友';
  end if;

  return query
    select u.id, u.display_name, u.avatar_path, ubc.added_at, ubc.invited_by
      from pendingbot.user_bot_contacts ubc
      join pendingbot.users u on u.id = ubc.user_id
     where ubc.bot_id = p_bot_id
     order by ubc.added_at desc;
end $$;

ALTER FUNCTION pendingbot.get_bot_friends(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.get_bot_friends(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.get_bot_friends(uuid) TO authenticated;

COMMIT;
