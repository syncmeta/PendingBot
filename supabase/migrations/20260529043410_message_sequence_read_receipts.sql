-- Message ordering + read-receipt foundation.
--
-- The old realtime path let Postgres fan every user_unread_counts row
-- through pg_net. A 30-person group message therefore produced one
-- messages webhook plus up to 30 unread webhooks. This migration keeps
-- the DB as source-of-record, but moves user-hub fanout to the Worker:
-- messages still get a conv-level webhook, while unread/list updates are
-- published by Edge after it has the full conversation context.

ALTER TABLE pendingbot.conversations
  ADD COLUMN IF NOT EXISTS message_seq_counter bigint NOT NULL DEFAULT 0;

ALTER TABLE pendingbot.messages
  ADD COLUMN IF NOT EXISTS message_seq bigint;

ALTER TABLE pendingbot.conversation_participants
  ADD COLUMN IF NOT EXISTS last_read_message_seq bigint;

ALTER TABLE pendingbot.user_unread_counts
  ADD COLUMN IF NOT EXISTS last_message_seq bigint;

-- Backfill stable per-conversation ordering for existing rows.
WITH numbered AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY conversation_id
      ORDER BY created_at ASC, id ASC
    )::bigint AS seq
  FROM pendingbot.messages
  WHERE message_seq IS NULL
)
UPDATE pendingbot.messages m
   SET message_seq = numbered.seq
  FROM numbered
 WHERE m.id = numbered.id;

UPDATE pendingbot.conversations c
   SET message_seq_counter = COALESCE(mx.max_seq, 0)
  FROM (
    SELECT conversation_id, max(message_seq) AS max_seq
      FROM pendingbot.messages
     GROUP BY conversation_id
  ) mx
 WHERE c.id = mx.conversation_id;

UPDATE pendingbot.user_unread_counts u
   SET last_message_seq = m.message_seq
  FROM pendingbot.messages m
 WHERE u.last_message_id = m.id
   AND u.last_message_seq IS NULL;

UPDATE pendingbot.conversation_participants cp
   SET last_read_message_seq = m.message_seq
  FROM pendingbot.messages m
 WHERE cp.last_read_message_id = m.id
   AND cp.last_read_message_seq IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS messages_conversation_seq_idx
  ON pendingbot.messages (conversation_id, message_seq)
  WHERE message_seq IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messages_conv_seq
  ON pendingbot.messages (conversation_id, message_seq DESC)
  WHERE message_seq IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_unread_counts_user_seq
  ON pendingbot.user_unread_counts (user_id, last_message_seq DESC);

CREATE OR REPLACE FUNCTION pendingbot.assign_message_seq()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, pg_temp
AS $$
DECLARE
  next_seq bigint;
BEGIN
  IF NEW.message_seq IS NULL THEN
    UPDATE pendingbot.conversations
       SET message_seq_counter = message_seq_counter + 1,
           updated_at = now()
     WHERE id = NEW.conversation_id
     RETURNING message_seq_counter INTO next_seq;

    IF next_seq IS NULL THEN
      RAISE EXCEPTION 'conversation not found for message seq assignment';
    END IF;

    NEW.message_seq := next_seq;
  ELSE
    UPDATE pendingbot.conversations
       SET message_seq_counter = GREATEST(message_seq_counter, NEW.message_seq),
           updated_at = now()
     WHERE id = NEW.conversation_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS messages_assign_seq_before_insert
  ON pendingbot.messages;

CREATE TRIGGER messages_assign_seq_before_insert
  BEFORE INSERT ON pendingbot.messages
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot.assign_message_seq();

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

  -- A human sender is, by definition, reading through the message they
  -- just submitted. This keeps "I sent a message" from leaving stale
  -- unread badges on the sender's own devices.
  if new.user_id is not null then
    update pendingbot.conversation_participants
       set last_read_message_id = new.id,
           last_read_message_seq = new.message_seq
     where conversation_id = new.conversation_id
       and participant_type = 'user'
       and participant_id = new.user_id;
  end if;

  insert into pendingbot.user_unread_counts (
    user_id, conversation_id, unread_count,
    last_message_id, last_message_seq, last_message_at, last_message_preview
  )
  select
    cp.participant_id,
    new.conversation_id,
    case when cp.participant_id = new.user_id then 0 else 1 end,
    new.id,
    new.message_seq,
    new.created_at,
    left(coalesce(new.content, ''), 100)
  from pendingbot.conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.participant_type = 'user'
  on conflict (user_id, conversation_id) do update
    set unread_count = case
          when pendingbot.user_unread_counts.user_id = new.user_id
            then 0
          else pendingbot.user_unread_counts.unread_count + 1
        end,
        last_message_id = new.id,
        last_message_seq = new.message_seq,
        last_message_at = new.created_at,
        last_message_preview = left(coalesce(new.content, ''), 100);
  return new;
end;
$$;

-- Stop per-recipient DB -> Edge webhook fanout. Edge now publishes
-- user-level state after message writes/read acks.
DROP TRIGGER IF EXISTS realtime_notify
  ON pendingbot.user_unread_counts;
