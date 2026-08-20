-- Fix: sender's conv list goes stale after they send a message.
--
-- update_unread_counts() (0044) skips the sender entirely
-- (`cp.participant_id is distinct from new.user_id`) because they
-- shouldn't see their own message bump their unread badge. But
-- pendingbot.user_unread_counts also carries the row's
-- last_message_at / last_message_id / last_message_preview, and iOS's
-- MessageTabView reads `last_activity_at` straight off this table to
-- order rows and render the row's preview. Because the trigger never
-- touches the sender's row, the row stays at whatever timestamp the
-- last *received* message had — so on the sender's device the conv
-- they just messaged shows "16 小时前 / 456" instead of "刚刚 /
-- <last text>", and Realtime never fires either (no UPDATE event)
-- so the list also doesn't auto-reload until some other trigger
-- (the recipient's reply, or a tab-switch refetch) wakes it up.
--
-- Fix: include the sender in the upserted set, but keep their
-- unread_count where it is (no badge bump). last_message_* still
-- updates so the conv row sorts and previews correctly, and the
-- accompanying Realtime UPDATE wakes MessageTabView's load() on
-- the sender's device.

CREATE OR REPLACE FUNCTION pendingbot.update_unread_counts() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pendingbot, pg_temp
    AS $$
begin
  if new.role = 'log' or new.status = 'replaced' then
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
