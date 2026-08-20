-- 20260520103221_fix_bootstrap_user_id_self_conv
--
-- 20260520102713 重写 bootstrap_user_id 时漏掉了末尾对 ensure_self_conv
-- + seed_example_letter 的调用（20260519101219 引进），新用户会拿不到
-- 「读我」预设来信。补回来。
--
-- 顺手修一个先前遗留的 bug：seed_example_letter 还在引用 scroll_runs，
-- 而 20260520034033 已经把它改名成 envelope_runs。函数对新用户必炸。

BEGIN;

SET search_path TO pendingbot, public;

-- ── seed_example_letter：scroll_runs → envelope_runs ─────────────────
CREATE OR REPLACE FUNCTION pendingbot.seed_example_letter(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  bot_id_v   uuid;
  conv_id_v  uuid;
  bot_slug_v text;
  exists_v   boolean;
  letter_v   pendingbot.preset_letters%rowtype;
begin
  if p_user_id is null then return; end if;

  select * into letter_v
    from pendingbot.preset_letters
   where slug = 'readme';
  if not found then return; end if;

  bot_slug_v := 'self-' || p_user_id::text;

  select id into bot_id_v
    from pendingbot.bots
   where slug = bot_slug_v;
  if bot_id_v is null then return; end if;

  select id into conv_id_v
    from pendingbot.conversations
   where user_id = p_user_id and conversation_type = 'self'
   limit 1;
  if conv_id_v is null then return; end if;

  select exists(
    select 1 from pendingbot.envelope_runs
     where user_id = p_user_id and trigger = 'example'
  ) into exists_v;
  if exists_v then return; end if;

  insert into pendingbot.envelope_runs (
    user_id, bot_id, conversation_id,
    status, title, summary, body_md,
    trigger, started_at, finished_at
  )
  values (
    p_user_id, bot_id_v, conv_id_v,
    'done',
    letter_v.title, letter_v.summary, letter_v.body_md,
    'example',
    now(),
    now()
  );
end $$;

ALTER FUNCTION pendingbot.seed_example_letter(uuid) OWNER TO postgres;

-- ── bootstrap_user_id：补回 self 会话 + 预设来信调用 ─────────────────
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

  perform pendingbot.ensure_preset_handle(p_uid);

  for bot_row in
    select id, slug, display_name, model_id, output_mode, is_active, config, visibility
      from pendingbot.bots
     where is_active = true and creator_id is null
  loop
    preset_title := case bot_row.slug
      when 'lorem'      then '大概介绍这个 App'
      when 'ipsum'      then '公有私有机器人'
      when 'dolor'      then 'Grok - 群'
      when 'sit'        then '同一个机器人可以有多个会话/模型'
      when 'amet'       then '我能为你做些什么？'
      when 'adipiscing' then 'Gemini 3.5 Flash - 打电话'
      else null
    end;

    if preset_title is null then
      continue;
    end if;

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

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, target_bot_id, bot_row.slug);
  end loop;

  -- 物化 self 会话并种下预设来信。
  perform pendingbot.ensure_self_conv(p_uid);
  perform pendingbot.seed_example_letter(p_uid);
end $$;

COMMIT;
