-- Patch uuidv7 to qualify gen_random_bytes — Supabase puts pgcrypto in
-- the `extensions` schema, which isn't on the default search_path so
-- migrations run by the postgres role can't resolve the unqualified
-- name. Without this, every INSERT into a uuidv7-default table errors.
create or replace function pendingbot.uuidv7()
returns uuid
language plpgsql
volatile
as $$
declare
  unix_ts_ms bigint;
  uuid_bytes bytea;
begin
  unix_ts_ms = (extract(epoch from clock_timestamp()) * 1000)::bigint;
  uuid_bytes = extensions.gen_random_bytes(16);
  uuid_bytes = set_byte(uuid_bytes, 0, ((unix_ts_ms >> 40) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 1, ((unix_ts_ms >> 32) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 2, ((unix_ts_ms >> 24) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 3, ((unix_ts_ms >> 16) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 4, ((unix_ts_ms >>  8) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 5, ( unix_ts_ms        & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 6, (112 | (get_byte(uuid_bytes, 6) & 15))::int);
  uuid_bytes = set_byte(uuid_bytes, 8, (128 | (get_byte(uuid_bytes, 8) & 63))::int);
  return encode(uuid_bytes, 'hex')::uuid;
end;
$$;

-- Preset "friends" — a small roster of bots every new user gets a
-- conversation with on first sign-in. Per plan/02 there's no static
-- persona; each bot starts from the identity-quest meta-prompt and
-- evolves via Honcho. Differentiation here is just name + model + mode,
-- so they feel distinct from the first turn while still discovering
-- themselves through use.

-- Re-slug the smoke-test 小绿 so the upsert below treats it as the
-- canonical "xiaolu" preset rather than a duplicate.
update pendingbot.bots set slug = 'xiaolu'
  where display_name = '小绿' and slug = 'default';

insert into pendingbot.bots (slug, display_name, model_id, output_mode)
values
  ('xiaolu',  '小绿',  'anthropic/claude-haiku-4-5',  'bubble'),
  ('lao-zhou','老周',  'anthropic/claude-opus-4-7',   'single'),
  ('arong',   '阿榕',  'openai/gpt-5',                'bubble'),
  ('jian',    '简',    'google/gemini-2.5-pro',       'single')
on conflict (slug) do nothing;

-- Bootstrap a user on first sign-in:
--   1. mirror auth.users → pendingbot.users
--   2. open a user_bot conversation with every active preset bot the
--      user doesn't already have one with
--   3. record the participant rows so RLS lets the user read the conv
--
-- security definer so the function can write to pendingbot.* under the
-- postgres role; users only ever invoke it indirectly via the trigger.

create or replace function pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb)
returns void
language plpgsql
security definer
set search_path = pendingbot, public
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

  for bot_row in
    select id, display_name from pendingbot.bots where is_active = true
  loop
    -- Skip if the user already has a user_bot conv with this bot.
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
      ('user_bot', 'message', p_uid, bot_row.id, bot_row.display_name)
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');
  end loop;
end $$;

create or replace function pendingbot.bootstrap_new_user_trigger() returns trigger
language plpgsql
security definer
as $$
begin
  perform pendingbot.bootstrap_user_id(new.id, new.email, new.raw_user_meta_data);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function pendingbot.bootstrap_new_user_trigger();

-- Backfill anyone who signed up before this migration ran.
do $$
declare u record;
begin
  for u in select id, email, raw_user_meta_data from auth.users loop
    perform pendingbot.bootstrap_user_id(u.id, u.email, u.raw_user_meta_data);
  end loop;
end $$;
