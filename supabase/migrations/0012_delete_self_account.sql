-- Self-serve account deletion. Wipes everything tied to the caller and
-- removes the auth.users row, which cascades the rest of the
-- pendingbot.* tables that already declare ON DELETE CASCADE.
--
-- Why a security-definer function instead of a Worker endpoint:
--   * deletes from auth.users which only the postgres role can touch.
--   * keeps the cleanup atomic (single transaction); a Worker would
--     have to fan out 6 deletes and might leave half-state on retry.

create or replace function pendingbot.delete_self_account()
returns void
language plpgsql
security definer
set search_path = pendingbot, public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'auth required';
  end if;

  -- 1. Tables whose FKs to auth.users are NOT on-delete-cascade. Order
  --    matters: messages → participants → conversations (FK chain).
  delete from pendingbot.messages where user_id = uid;
  -- conversation_participants references conversations(id) on cascade,
  -- so it'll auto-clear when we drop the convs below — but the rows
  -- where the user appears as participant in someone else's conv
  -- (group / user_user) need their own delete since their conv stays.
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = uid;
  delete from pendingbot.conversations where user_id = uid;

  -- 2. ON DELETE CASCADE will handle: user_unread_counts, user_handles,
  --    user_contacts (both sides), device_tokens, ai_picks, skills,
  --    portrait_conversations, bot_reflections, plus pendingbot.users.

  -- 3. Drop the auth row last; this fires the cascading deletes above.
  delete from auth.users where id = uid;
end $$;

grant execute on function pendingbot.delete_self_account() to authenticated;
