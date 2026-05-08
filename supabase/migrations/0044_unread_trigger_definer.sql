-- Fix: sending a message in a user_user conversation fails with
--   new row violates row-level security policy for table "user_unread_counts"
--
-- The AFTER INSERT trigger on pendingbot.messages calls
-- update_unread_counts(), which inserts/updates a row in
-- user_unread_counts for every OTHER participant of the conversation.
-- With SECURITY INVOKER (the default), that insert runs as the message
-- sender — but user_unread_counts has RLS enabled with only SELECT and
-- UPDATE policies scoped to user_id = auth.uid(), and no INSERT policy.
-- Inserting a row whose user_id is the *recipient* therefore fails.
--
-- Bot conversations didn't expose this because the trigger skips the
-- sender themselves and bot conversations have only one human
-- participant — so no rows are inserted at all. user_user (and group)
-- conversations always have ≥1 other human, which is what surfaced the
-- bug.
--
-- Fix: rebuild the function with SECURITY DEFINER. The function is
-- owned by `postgres`, which bypasses RLS on tables that don't have
-- FORCE ROW LEVEL SECURITY (user_unread_counts doesn't), so the insert
-- proceeds regardless of who triggered the message insert.
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
    1,
    new.id,
    new.created_at,
    left(coalesce(new.content, ''), 100)
  from pendingbot.conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.participant_type = 'user'
    and cp.participant_id is distinct from new.user_id
  on conflict (user_id, conversation_id) do update
    set unread_count = pendingbot.user_unread_counts.unread_count + 1,
        last_message_id = new.id,
        last_message_at = new.created_at,
        last_message_preview = left(coalesce(new.content, ''), 100);
  return new;
end;
$$;
