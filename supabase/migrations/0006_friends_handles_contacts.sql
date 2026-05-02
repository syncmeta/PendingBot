-- Friends model: handles + contacts.
--
-- handles  = a user can mint multiple shareable codes (via QR / paste a
--            number). Each is independently revokable and can be labeled
--            so the owner remembers where they shared it.
-- contacts = mutual edge between two users. When A adds B via a handle
--            (or email), the Worker writes BOTH rows symmetrically so B
--            also sees A in their list.
--
-- Add-by-handle lookup goes through the Worker (service_role) — RLS
-- doesn't allow reading anyone else's handles, by design.

create table if not exists pendingbot.user_handles (
  id uuid primary key default pendingbot.uuidv7(),
  user_id uuid not null references auth.users(id) on delete cascade,
  -- UX hint only: 'number' = plain code paste; 'qr' = same code, just
  -- rendered as a QR by the UI. Schema-side they're equivalent.
  kind text not null default 'number' check (kind in ('number', 'qr')),
  -- The shareable secret. Random 10-char base32 string. Owner shares
  -- the value publicly; anyone holding it can add the owner as a contact
  -- until is_active flips to false.
  value text not null unique,
  label text,                           -- "blog readers", "twitter", etc
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists idx_handles_user_active
  on pendingbot.user_handles (user_id, is_active);

create table if not exists pendingbot.user_contacts (
  -- Primary key is the (owner, friend) pair so the same edge can't be
  -- inserted twice. The Worker INSERTs both directions on a successful
  -- add, so each side independently sees the relation.
  user_id uuid not null references auth.users(id) on delete cascade,
  contact_user_id uuid not null references auth.users(id) on delete cascade,
  -- The handle of contact_user_id that user_id used to find them. Null
  -- if added via email or system invite. Each side's row records the
  -- same handle so both can audit how they got connected.
  added_via_handle_id uuid references pendingbot.user_handles(id) on delete set null,
  alias text,                            -- this side's nickname for the other
  created_at timestamptz not null default now(),
  primary key (user_id, contact_user_id),
  check (user_id <> contact_user_id)
);

create index if not exists idx_contacts_contact
  on pendingbot.user_contacts (contact_user_id);

alter table pendingbot.user_handles enable row level security;
alter table pendingbot.user_contacts enable row level security;

-- handles: only the owner ever touches them.
create policy handles_owner_read on pendingbot.user_handles
  for select using (user_id = auth.uid());
create policy handles_owner_write on pendingbot.user_handles
  for insert with check (user_id = auth.uid());
create policy handles_owner_update on pendingbot.user_handles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy handles_owner_delete on pendingbot.user_handles
  for delete using (user_id = auth.uid());

-- contacts: caller sees only their own row of the pair; the symmetric
-- row from the other side belongs to the other user.
create policy contacts_self_read on pendingbot.user_contacts
  for select using (user_id = auth.uid());
-- Direct INSERT/UPDATE/DELETE via PostgREST is restricted to "rename your
-- own alias" / "remove a contact"; the add flow goes through the Worker
-- which writes the symmetric pair under service_role.
create policy contacts_self_update on pendingbot.user_contacts
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy contacts_self_delete on pendingbot.user_contacts
  for delete using (user_id = auth.uid());

grant select, update, delete on pendingbot.user_handles to authenticated;
grant insert on pendingbot.user_handles to authenticated;
grant select, update, delete on pendingbot.user_contacts to authenticated;
grant select, insert, update, delete on pendingbot.user_handles to service_role;
grant select, insert, update, delete on pendingbot.user_contacts to service_role;
