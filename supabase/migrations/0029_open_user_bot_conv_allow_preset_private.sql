-- Bugfix: open_user_bot_conv was rejecting preset private bots.
--
-- Migration 0023 changed several preset bots (lorem/sit/amet/consectetur)
-- to visibility='private' while keeping creator_id IS NULL (preset rows
-- are system-owned). The SELECT-side RLS (bots_visible_read) was widened
-- in the same migration so users could still see private presets they
-- had a bootstrapped conv with — but the open_user_bot_conv RPC was not
-- updated, so its private check
--
--     bot_row.creator_id IS DISTINCT FROM caller_id
--
-- evaluates TRUE for NULL creator_id and the user gets
-- "没有权限打开此机器人" when tapping a preset private bot from FriendsTab
-- and triggering the lazy conv materialization (materializeIfPending →
-- RPC). They cannot start a fresh conversation with their preset bots.
--
-- Fix: treat preset (creator_id IS NULL) bots as openable by any
-- authenticated user regardless of visibility. Preset visibility = 'private'
-- still constrains other things (no invitee management, etc.) but should
-- not block the user from chatting with them.

BEGIN;

CREATE OR REPLACE FUNCTION pendingbot.open_user_bot_conv(p_bot_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id uuid := auth.uid();
  conv_id   uuid;
  bot_row   record;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select id, visibility, creator_id, is_active into bot_row
    from pendingbot.bots where id = p_bot_id;

  if bot_row is null or bot_row.is_active = false then
    raise exception 'bot not found or inactive';
  end if;

  -- Preset bots (creator_id IS NULL) are system-owned and openable by
  -- anyone authed regardless of visibility. Only user-owned private
  -- bots gate on creator match.
  if bot_row.visibility = 'private'
     and bot_row.creator_id is not null
     and bot_row.creator_id is distinct from caller_id then
    raise exception '没有权限打开此机器人';
  end if;

  if bot_row.visibility = 'public_invite'
     and bot_row.creator_id is distinct from caller_id
     and not exists (
       select 1 from pendingbot.bot_invites
        where bot_id = p_bot_id and user_id = caller_id
     ) then
    raise exception '没有权限打开此机器人';
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('user_bot', 'message', caller_id, p_bot_id,
     coalesce(pendingbot.random_place_name(), '新对话'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  p_bot_id,  'member');

  return conv_id;
end $$;

COMMIT;
