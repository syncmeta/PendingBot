-- Fix infinite RLS recursion → "stack depth limit exceeded".
--
-- pendingbot.is_participant(conv_id) was declared `security invoker`,
-- so its inner SELECT against pendingbot.conversation_participants ran
-- under the caller's RLS — and the table's `participants_self_read`
-- policy is itself defined as
--   (participant_type='user' AND participant_id=auth.uid())
--   OR pendingbot.is_participant(conversation_id)
-- so any non-self row fell into the OR branch, which re-entered
-- is_participant for the same conversation_id, which fetched the same
-- rows under RLS, and so on. Postgres hit max_stack_depth and aborted
-- the query with "stack depth limit exceeded" — typically the moment
-- the conv-list query embeds a row whose participants include a bot
-- or a different user (group / user_user / discuss).
--
-- security definer makes the helper run as the function owner, so its
-- inner SELECT bypasses RLS — exactly the behaviour we want for a
-- predicate that's *defining* RLS for other tables.

create or replace function pendingbot.is_participant(conv_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pendingbot, public
as $$
  select exists (
    select 1 from pendingbot.conversation_participants
    where conversation_id = conv_id
      and participant_type = 'user'
      and participant_id = auth.uid()
  );
$$;

grant execute on function pendingbot.is_participant(uuid) to authenticated;
