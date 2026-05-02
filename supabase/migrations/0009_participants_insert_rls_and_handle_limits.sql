-- 1. RLS for conversation_participants INSERT.
--
--    The owner of a freshly-created conversation needs to seed the
--    participant rows from the iOS client. Schema 0001 only had a SELECT
--    policy, so all direct inserts were getting denied. Two policies:
--
--    a) when the caller is the conv's owner (i.e. they just inserted
--       the conversation row), they may insert ANY participant — themselves,
--       a bot they want pinned, etc.
--    b) once a conv has any participants, an existing participant can
--       invite others (used for adding people to a group later).

drop policy if exists participants_owner_seed on pendingbot.conversation_participants;
create policy participants_owner_seed on pendingbot.conversation_participants
  for insert with check (
    exists (
      select 1 from pendingbot.conversations
       where id = conversation_id and user_id = auth.uid()
    )
  );

-- 2. user_handles: per-user max 5 active, custom-friendly format.
--
--    a) format constraint: 4-20 chars, [A-Z0-9 _-]. Avoids confusing
--       characters by convention (no 0/O 1/L) but the regex itself
--       just bounds the alphabet so users can pick memorable codes.
--    b) trigger enforces ≤5 active handles per user on INSERT and on
--       UPDATE that flips is_active false→true.

alter table pendingbot.user_handles
  drop constraint if exists handles_value_format;
alter table pendingbot.user_handles
  add constraint handles_value_format check (
    value ~ '^[A-Za-z0-9_-]{4,20}$'
  );

create or replace function pendingbot.check_handle_limit() returns trigger
language plpgsql
as $$
declare
  active_count int;
begin
  -- Only count if the new row is active (insert active OR re-activating).
  if not new.is_active then
    return new;
  end if;
  -- For UPDATE re-activating, exclude the current row from the count
  -- (it's about to become active; we count *post* the change).
  select count(*) into active_count
    from pendingbot.user_handles
   where user_id = new.user_id
     and is_active = true
     and (tg_op = 'INSERT' or id <> new.id);
  if active_count >= 5 then
    raise exception 'handle limit: at most 5 active handles per user';
  end if;
  return new;
end $$;

drop trigger if exists handles_limit on pendingbot.user_handles;
create trigger handles_limit
  before insert or update on pendingbot.user_handles
  for each row execute function pendingbot.check_handle_limit();
