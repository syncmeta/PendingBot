-- 20260519101219_seed_preset_letter_on_signup — 注册即收到预设来信
--
-- 此前预设来信（trigger='example' 的「读我」）只在 open_self_conv() 里
-- 种下，而 open_self_conv() 只在用户主动点开「我自己」会话时才被 iOS
-- 调用。新用户注册后若直接去「来信」tab，self-bot / self-conv 都还没
-- 物化，seed_example_letter() 从没跑过 —— 来信列表是空的。
--
-- 修法：把 self-bot + self-conv 的 find-or-create 抽成 ensure_self_conv()，
-- 让 bootstrap_user_id（auth.users AFTER INSERT 触发器）在 onboarding 时
-- 就物化 self 会话并种下预设来信。open_self_conv() 改为复用同一 helper，
-- 两条路径不再各写一份逻辑。
--
--   1. ensure_self_conv(p_uid) —— 共享的 find-or-create
--   2. open_self_conv() 改为 ensure_self_conv(auth.uid()) + seed
--   3. bootstrap_user_id 末尾 ensure_self_conv + seed_example_letter
--   4. backfill：给所有既有用户补 self-conv + 预设来信

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. 共享 helper：find-or-create 用户的 self-bot + self-conv ──────────
CREATE OR REPLACE FUNCTION pendingbot.ensure_self_conv(p_uid uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  bot_uuid    uuid;
  conv_id     uuid;
  caller_name text;
  bot_slug    text;
begin
  if p_uid is null then
    raise exception 'ensure_self_conv: p_uid required';
  end if;

  bot_slug := 'self-' || p_uid::text;

  select coalesce(nullif(display_name, ''), '你') into caller_name
    from pendingbot.users where id = p_uid;

  -- Find or create the per-user self-bot.
  select id into bot_uuid
    from pendingbot.bots
   where slug = bot_slug;

  if bot_uuid is null then
    insert into pendingbot.bots
      (slug, display_name, model_id, output_mode, creator_id, visibility, is_active)
    values
      (bot_slug,
       coalesce(caller_name, '我'),
       '~google/gemini-flash-latest',
       'bubble',
       p_uid,
       'private',
       true)
    returning id into bot_uuid;
  end if;

  -- Reuse if a self conv already exists.
  select id into conv_id
    from pendingbot.conversations
   where user_id = p_uid and conversation_type = 'self'
   limit 1;
  if conv_id is not null then
    return conv_id;
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('self', 'message', p_uid, bot_uuid, coalesce(caller_name, '我自己'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', p_uid, 'owner'),
    (conv_id, 'bot',  bot_uuid,  'member');

  return conv_id;
end $$;

ALTER FUNCTION pendingbot.ensure_self_conv(uuid) OWNER TO postgres;

-- ── 2. open_self_conv()：改为复用 helper ──────────────────────────────
CREATE OR REPLACE FUNCTION pendingbot.open_self_conv() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id uuid := auth.uid();
  conv_id   uuid;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  conv_id := pendingbot.ensure_self_conv(caller_id);
  perform pendingbot.seed_example_letter(caller_id);
  return conv_id;
end $$;

ALTER FUNCTION pendingbot.open_self_conv() OWNER TO postgres;

-- ── 3. bootstrap_user_id：onboarding 时物化 self-conv + 种预设来信 ─────
CREATE OR REPLACE FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pendingbot', 'public'
  AS $$
declare
  bot_row       record;
  conv_id       uuid;
  preset_title  text;
  target_bot_id uuid;
  clone_slug    text;
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

  -- Seed onboarding conversations against preset bots (creator_id IS NULL).
  for bot_row in
    select id, slug, display_name, model_id, output_mode, is_active, config, visibility
      from pendingbot.bots
     where is_active = true and creator_id is null
  loop
    preset_title := case bot_row.slug
      when 'lorem' then '大概介绍这个 App'
      when 'ipsum' then '公有私有机器人'
      when 'dolor' then '这个 App 八字没一撇呢'
      when 'sit'   then '同一个机器人可以有多个会话/模型'
      when 'amet'  then '我能为你做些什么？'
      else null
    end;

    -- 没有预置会话标题的预置 bot 不主动建会话 —— 留给用户自己发现。
    if preset_title is null then
      continue;
    end if;

    -- 私有预置 bot：creator_id-NULL 行是模板，按用户克隆成一份私有 bot。
    -- 公有预置 bot：共享，会话直接指向模板行。
    if bot_row.visibility = 'private' then
      clone_slug := bot_row.slug || '-' || p_uid::text;
      select id into target_bot_id from pendingbot.bots where slug = clone_slug;
      if target_bot_id is null then
        insert into pendingbot.bots
          (slug, display_name, model_id, output_mode, is_active, config, visibility, creator_id)
        values
          (clone_slug, bot_row.display_name, bot_row.model_id, bot_row.output_mode,
           bot_row.is_active, bot_row.config, 'private', p_uid)
        returning id into target_bot_id;
      end if;
    else
      target_bot_id := bot_row.id;
    end if;

    if exists (
      select 1 from pendingbot.conversations
       where user_id = p_uid
         and bot_id = target_bot_id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title)
    values
      ('user_bot', 'message', p_uid, target_bot_id, preset_title)
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  target_bot_id, 'member');

    -- seed_sample_dialogue 按模板 slug（lorem/ipsum/...）分支，传模板
    -- slug 而非克隆 slug。
    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, target_bot_id, bot_row.slug);
  end loop;

  -- 物化 self 会话并种下预设来信 —— 新用户进「来信」tab 即可看到「读我」，
  -- 不必先点开「我自己」会话。
  perform pendingbot.ensure_self_conv(p_uid);
  perform pendingbot.seed_example_letter(p_uid);
end $$;

ALTER FUNCTION pendingbot.bootstrap_user_id(uuid, text, jsonb) OWNER TO postgres;

-- ── 4. Backfill：给所有既有用户补 self-conv + 预设来信 ─────────────────
DO $$
declare
  u_id uuid;
begin
  for u_id in select id from pendingbot.users
  loop
    perform pendingbot.ensure_self_conv(u_id);
    perform pendingbot.seed_example_letter(u_id);
  end loop;
end $$;

COMMIT;
