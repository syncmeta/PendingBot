-- Lookback notes — bot-private "context edits" injected into the conv
-- on its own time (similar trigger to the old auto-review, totally
-- different mechanism). The bot is asked to look at the running
-- transcript and write a fact-check / clarification note for itself;
-- the note is invisible to the user, lives as a context block in
-- subsequent prompts until the bot decides to drop it.
--
-- See plan/02 + the lookback-runner for full mechanism.

create table if not exists pendingbot.bot_lookbacks (
  id uuid primary key default pendingbot.uuidv7(),
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  bot_id uuid not null references pendingbot.bots(id) on delete cascade,
  body_md text not null,
  -- Toggle managed by the bot itself: emits [DROP_LOOKBACK] at the end of
  -- a normal reply when it judges this note isn't relevant anymore.
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_lookbacks_conv_active
  on pendingbot.bot_lookbacks (conversation_id, active, created_at desc);

-- Realtime publication so the iOS client picks up new lookbacks without
-- polling. Push includes the body_md (RLS allows the user to read their
-- conv's notes — UI just chooses not to display them).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'pendingbot'
      and tablename = 'bot_lookbacks'
  ) then
    execute 'alter publication supabase_realtime add table pendingbot.bot_lookbacks';
  end if;
end $$;

alter table pendingbot.bot_lookbacks enable row level security;

-- A user can read every lookback for any conv they participate in; the
-- iOS client uses this both for the Realtime subscription and as a
-- fallback fetch on cold launch. Writes are service-role only (Worker).
drop policy if exists lookbacks_participant_read on pendingbot.bot_lookbacks;
create policy lookbacks_participant_read on pendingbot.bot_lookbacks
  for select using (pendingbot.is_participant(conversation_id));

grant select on pendingbot.bot_lookbacks to authenticated, anon;
grant select, insert, update, delete on pendingbot.bot_lookbacks to service_role;
