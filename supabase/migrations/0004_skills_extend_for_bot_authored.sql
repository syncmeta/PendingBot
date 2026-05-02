-- Extend `skills` so it covers three kinds of authorship:
--   1. user-authored        owner_id set, bot_id/user_id null
--   2. bot-authored note    bot_id + user_id set, owner_id null;
--                           bot's private "manual on how to relate to
--                           this user" — never visible to that user
--   3. system-seeded public  all three null, visibility='public'
--                           (the bundled Anthropic Claude Skills)
--
-- Adds RLS that hides class 2 from any non-service-role caller.

alter table pendingbot.skills
  add column if not exists bot_id  uuid references pendingbot.bots(id) on delete cascade,
  add column if not exists user_id uuid references auth.users(id) on delete cascade,
  alter column owner_id drop not null;

alter table pendingbot.skills drop constraint if exists skills_authorship;
alter table pendingbot.skills add constraint skills_authorship check (
  -- bot-authored note about a specific user
  (bot_id is not null and user_id is not null and owner_id is null)
  or
  -- user-authored
  (bot_id is null and user_id is null and owner_id is not null)
  or
  -- system-seeded public (no human owner; only public visibility allowed)
  (bot_id is null and user_id is null and owner_id is null and visibility = 'public')
);

create index if not exists idx_skills_bot_user
  on pendingbot.skills (bot_id, user_id)
  where bot_id is not null;

-- Replace any existing per-row policies with the new authorship-aware set.
-- Anything we miss in the drop is harmless because RLS is "deny by default".
do $$
declare p text;
begin
  for p in
    select policyname from pg_policies
    where schemaname = 'pendingbot' and tablename = 'skills'
  loop
    execute format('drop policy if exists %I on pendingbot.skills', p);
  end loop;
end $$;

create policy skills_read on pendingbot.skills
  for select using (
    -- I own it
    (owner_id = auth.uid())
    -- or it's a system-seeded / public-shared user skill
    or (bot_id is null and visibility = 'public')
    -- bot-authored notes are NOT readable by the user; only service_role
    -- (Worker) bypasses RLS.
  );
create policy skills_user_insert on pendingbot.skills
  for insert with check (owner_id = auth.uid() and bot_id is null and user_id is null);
create policy skills_user_update on pendingbot.skills
  for update using  (owner_id = auth.uid() and bot_id is null)
                with check (owner_id = auth.uid() and bot_id is null);
create policy skills_user_delete on pendingbot.skills
  for delete using (owner_id = auth.uid() and bot_id is null);
