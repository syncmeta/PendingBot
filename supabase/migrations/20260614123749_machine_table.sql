-- First-class `machine` concept: 本机 / peer / fly all live in one table.
-- A crew (temporary_group_meta) will reference a machine via machine_id (File 2).
-- runtime_location stays as a DERIVED value computed at write time from the chosen machine.
--
-- subjects columns verified against apps/edge/src/db/schema.ts (subjects.Row):
--   id uuid, subject_type text, user_id uuid|null — used by the RLS policies below.
set search_path = pendingbot, public;

create table pendingbot.machine (
  id              uuid primary key default gen_random_uuid(),
  subject_id      uuid not null references pendingbot.subjects(id) on delete cascade,
  kind            text not null check (kind in ('computer','fly')),
  device_id       text,
  display_name    text not null,
  fly_machine_id  text,
  status          text,
  last_seen_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint machine_kind_target_chk check (
    (kind = 'computer' and device_id is not null and fly_machine_id is null)
    or (kind = 'fly' and fly_machine_id is not null)
  )
);

create unique index machine_subject_device_uniq
  on pendingbot.machine (subject_id, device_id) where device_id is not null;
create index machine_subject_idx on pendingbot.machine (subject_id, created_at desc);

alter table pendingbot.machine enable row level security;

create policy machine_self_read on pendingbot.machine for select
  using (exists (select 1 from pendingbot.subjects s
    where s.id = machine.subject_id and s.subject_type = 'user_account' and s.user_id = auth.uid()));
create policy machine_self_insert on pendingbot.machine for insert
  with check (exists (select 1 from pendingbot.subjects s
    where s.id = machine.subject_id and s.subject_type = 'user_account' and s.user_id = auth.uid()));
create policy machine_self_update on pendingbot.machine for update
  using (exists (select 1 from pendingbot.subjects s
    where s.id = machine.subject_id and s.subject_type = 'user_account' and s.user_id = auth.uid()))
  with check (exists (select 1 from pendingbot.subjects s
    where s.id = machine.subject_id and s.subject_type = 'user_account' and s.user_id = auth.uid()));
create policy machine_self_delete on pendingbot.machine for delete
  using (exists (select 1 from pendingbot.subjects s
    where s.id = machine.subject_id and s.subject_type = 'user_account' and s.user_id = auth.uid()));

grant select, insert, update, delete on table pendingbot.machine to authenticated;
grant select, insert, update, delete on table pendingbot.machine to service_role;

create or replace function pendingbot.upsert_self_machine(
  p_subject_id uuid, p_device_id text, p_display_name text
) returns uuid language plpgsql security definer set search_path = pendingbot, public as $$
declare v_id uuid;
begin
  insert into pendingbot.machine (subject_id, kind, device_id, display_name, last_seen_at, status, updated_at)
  values (p_subject_id, 'computer', p_device_id, p_display_name, now(), 'online', now())
  on conflict (subject_id, device_id) where device_id is not null
  do update set display_name = excluded.display_name, last_seen_at = now(), status = 'online', updated_at = now()
  returning id into v_id;
  return v_id;
end; $$;
grant execute on function pendingbot.upsert_self_machine(uuid, text, text) to service_role;
