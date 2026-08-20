-- Lazy-cloud-conv flow: a single SECURITY DEFINER RPC that the worker calls
-- with the user's JWT to (a) gate-check bot visibility, (b) create the conv +
-- participant rows, and (c) insert the user message row. The worker then
-- streams runChatTurn against the returned ids — no separate "open conv"
-- round-trip from the client.
--
-- The RPC is idempotent on `client_message_id`: if a prior call by the same
-- user already inserted a row with that cmid, return its conv + message id
-- instead of stacking a duplicate conv. That makes a network-retry by the
-- client a no-op rather than spawning ghost convs.

BEGIN;

CREATE OR REPLACE FUNCTION pendingbot.start_user_bot_turn(
  p_bot_id              uuid,
  p_client_message_id   uuid,
  p_content             text,
  p_attachment_ids      uuid[] DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id   uuid := auth.uid();
  bot_row     record;
  conv_id     uuid;
  user_msg_id uuid;
  existing    record;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  -- Idempotent retry: a prior insert with this cmid means we already did
  -- the work; return its ids and bail.
  select m.id as message_id, m.conversation_id
    into existing
    from pendingbot.messages m
   where m.client_message_id = p_client_message_id
     and m.user_id = caller_id
   limit 1;
  if found then
    return jsonb_build_object(
      'conv_id',         existing.conversation_id,
      'user_message_id', existing.message_id
    );
  end if;

  -- Bot visibility gate (mirrors open_user_bot_conv at 0029).
  select id, visibility, creator_id, is_active into bot_row
    from pendingbot.bots where id = p_bot_id;
  if bot_row is null or bot_row.is_active = false then
    raise exception 'bot not found or inactive';
  end if;
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

  insert into pendingbot.messages
    (client_message_id, conversation_id, user_id, role, content,
     status, attachments)
  values
    (p_client_message_id, conv_id, caller_id, 'user', p_content,
     'done',
     case when p_attachment_ids is not null
       then jsonb_build_object('ids', to_jsonb(p_attachment_ids))
       else null end)
  returning id into user_msg_id;

  return jsonb_build_object(
    'conv_id',         conv_id,
    'user_message_id', user_msg_id
  );
end $$;

ALTER FUNCTION pendingbot.start_user_bot_turn(uuid, uuid, text, uuid[])
  OWNER TO postgres;
GRANT EXECUTE ON FUNCTION
  pendingbot.start_user_bot_turn(uuid, uuid, text, uuid[])
  TO authenticated;

COMMIT;
