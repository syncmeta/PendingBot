-- Preset random "ID" handle, auto-generated per user, immutable.
-- Lowers the privacy-handle (kind='number') limit from 5 to 3.
-- Adds a new kind='id' for the preset; users cannot create, modify, or
-- revoke kind='id' rows — only the bootstrap path inserts them, and
-- only auth.users CASCADE removes them.

set search_path = pendingbot, public;

-- 1. Allow kind='id' alongside the existing 'number' / 'qr'.
alter table pendingbot.user_handles
  drop constraint user_handles_kind_check;
alter table pendingbot.user_handles
  add constraint user_handles_kind_check
  check (kind in ('id', 'number', 'qr'));

-- 2. Privacy-handle limit drops 5 → 3. The preset 'id' handle is
--    excluded from the count.
create or replace function pendingbot.check_handle_limit() returns trigger
  language plpgsql
  as $$
declare
  active_count int;
begin
  if not new.is_active then
    return new;
  end if;
  if new.kind <> 'number' then
    return new;
  end if;
  select count(*) into active_count
    from pendingbot.user_handles
   where user_id = new.user_id
     and kind = 'number'
     and is_active = true
     and (tg_op = 'INSERT' or id <> new.id);
  if active_count >= 3 then
    raise exception 'handle limit: at most 3 active privacy handles per user';
  end if;
  return new;
end $$;

-- 3. Guard: only system paths (current_user = postgres / supabase_admin
--    via SECURITY DEFINER) can INSERT kind='id'; user roles
--    (authenticated / anon) cannot create, modify, or delete a kind='id'
--    row. CASCADE from auth.users.delete runs as the schema owner so it
--    bypasses this guard.
create or replace function pendingbot.guard_preset_handle() returns trigger
  language plpgsql
  as $$
begin
  if tg_op = 'INSERT' then
    if new.kind = 'id' and current_user in ('authenticated', 'anon') then
      raise exception 'preset ID handle cannot be created by users';
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    if old.kind = 'id' and current_user in ('authenticated', 'anon') then
      raise exception 'preset ID handle cannot be modified';
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    if old.kind = 'id' and current_user in ('authenticated', 'anon') then
      raise exception 'preset ID handle cannot be deleted';
    end if;
    return old;
  end if;
  return null;
end $$;

drop trigger if exists handles_guard_preset on pendingbot.user_handles;
create trigger handles_guard_preset
  before insert or update or delete on pendingbot.user_handles
  for each row execute function pendingbot.guard_preset_handle();

-- 4. 10-char value generator using the same alphabet iOS uses
--    (excludes 0/1/O/I/L for visual clarity).
create or replace function pendingbot.gen_preset_handle_value() returns text
  language plpgsql
  as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  out_value text := '';
  i int;
begin
  for i in 1..10 loop
    out_value := out_value || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return out_value;
end $$;

-- 5. Ensure exactly one preset 'id' handle per user; retries on the rare
--    uniqueness collision (32^10 ≈ 1.1e15, but bounded for safety).
create or replace function pendingbot.ensure_preset_handle(p_uid uuid) returns void
  language plpgsql
  security definer
  set search_path to 'pendingbot', 'public'
  as $$
declare
  candidate text;
  attempts int := 0;
begin
  if exists (
    select 1 from pendingbot.user_handles
     where user_id = p_uid and kind = 'id'
  ) then
    return;
  end if;
  loop
    attempts := attempts + 1;
    candidate := pendingbot.gen_preset_handle_value();
    begin
      insert into pendingbot.user_handles (user_id, kind, value, is_active)
      values (p_uid, 'id', candidate, true);
      return;
    exception when unique_violation then
      if attempts >= 8 then
        raise exception 'failed to generate unique preset handle after % attempts', attempts;
      end if;
    end;
  end loop;
end $$;

alter function pendingbot.ensure_preset_handle(uuid) owner to postgres;
revoke all on function pendingbot.ensure_preset_handle(uuid) from public;
revoke all on function pendingbot.gen_preset_handle_value() from public;

-- 6. Hook the preset into the new-user bootstrap path.
create or replace function pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) returns void
  language plpgsql security definer
  set search_path to 'pendingbot', 'public'
  as $$
declare
  bot_row record;
  conv_id uuid;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  -- Preset random ID — globally unique, immutable, exactly one per user.
  perform pendingbot.ensure_preset_handle(p_uid);

  for bot_row in
    select id, slug, display_name from pendingbot.bots where is_active = true
  loop
    if exists (
      select 1 from pendingbot.conversations
       where user_id = p_uid
         and bot_id = bot_row.id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title)
    values
      ('user_bot', 'message', p_uid, bot_row.id,
       coalesce(pendingbot.random_place_name(), bot_row.display_name))
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, bot_row.id, bot_row.slug);
  end loop;
end $$;

-- 7. Backfill: every existing auth.users row gets a preset ID.
do $$
declare
  u record;
begin
  for u in select id from auth.users loop
    perform pendingbot.ensure_preset_handle(u.id);
  end loop;
end $$;
