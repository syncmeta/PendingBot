-- 1. RPC: pendingbot.open_user_bot_conv(p_bot_id)
--
-- Atomically create a user_bot conversation owned by the caller plus
-- the (user, bot) participant rows, returning the new conv id. Runs as
-- security definer so RLS doesn't block the participant inserts even if
-- the calling JWT's id encoding ever drifts from the column type.
--
-- Why we need an RPC instead of direct iOS inserts:
--   * conv + participants is a 2-statement atomic unit; a separate iOS
--     trip would leave half-state if the second call fails.
--   * lets us evolve invariants (e.g. dedupe per-bot, attach default
--     skills) server-side without an iOS migration.

create or replace function pendingbot.open_user_bot_conv(p_bot_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pendingbot, public
as $$
declare
  caller_id uuid := auth.uid();
  bot_name  text;
  conv_id   uuid;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select display_name into bot_name
    from pendingbot.bots
   where id = p_bot_id and is_active = true;
  if bot_name is null then
    raise exception 'bot not found or inactive';
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('user_bot', 'message', caller_id, p_bot_id, bot_name)
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  p_bot_id,  'member');

  return conv_id;
end $$;

grant execute on function pendingbot.open_user_bot_conv(uuid) to authenticated;
