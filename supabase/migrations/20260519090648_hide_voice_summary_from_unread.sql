-- Keep voice-call recap rows out of the conversation-list preview.
--
-- The closing recap of a voice call is stored as a normal messages row
-- (role='bot', metadata.source='voice_call_summary'). It's deliberately
-- memory-only — the bot's long-term memory pipeline reads it, but it must
-- not surface in the timeline or the message-list preview.
--
-- update_unread_counts() already skips role='log' / status='replaced';
-- extend the same guard to voice_call_summary rows so they no longer
-- overwrite last_message_preview / last_message_at or bump unread_count.

CREATE OR REPLACE FUNCTION pendingbot.update_unread_counts() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pendingbot, pg_temp
    AS $$
begin
  if new.role = 'log'
     or new.status = 'replaced'
     or (new.metadata ->> 'source') = 'voice_call_summary' then
    return new;
  end if;

  insert into pendingbot.user_unread_counts (
    user_id, conversation_id, unread_count,
    last_message_id, last_message_at, last_message_preview
  )
  select
    cp.participant_id,
    new.conversation_id,
    -- New rows for the sender start at 0; everyone else starts at 1
    -- (the message they just received is unread).
    case when cp.participant_id = new.user_id then 0 else 1 end,
    new.id,
    new.created_at,
    left(coalesce(new.content, ''), 100)
  from pendingbot.conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.participant_type = 'user'
  on conflict (user_id, conversation_id) do update
    set unread_count = case
          when pendingbot.user_unread_counts.user_id = new.user_id
            then pendingbot.user_unread_counts.unread_count
          else pendingbot.user_unread_counts.unread_count + 1
        end,
        last_message_id = new.id,
        last_message_at = new.created_at,
        last_message_preview = left(coalesce(new.content, ''), 100);
  return new;
end;
$$;
