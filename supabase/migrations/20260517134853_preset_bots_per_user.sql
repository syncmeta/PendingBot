-- 预置机器人改为「私有=每用户一份副本，公有=共享」。
--
-- 此前 6 个私有预置 bot 是全局共享的单行（creator_id IS NULL），所有
-- 用户的同名私有预置 bot 指向同一行 —— 没有 owner，PATCH /v1/bots/:id
-- 的 `private && creator_id == userId` 门槛永远落空，谁都改不了配置。
--
-- 现在让预置 bot 跟普通用户 bot 一视同仁：
--   * 私有预置 bot 的 creator_id-NULL 行降级为「模板」（RLS 对所有人
--     不可见，永不直接挂到会话上）。onboarding 时按用户克隆成一份
--     creator_id = 该用户 的私有 bot，会话指向克隆。克隆后 owner 就是
--     该用户，编辑配置走普通私有 bot 流程，无需任何特例。
--   * 公有预置 bot 保持共享 —— 会话仍直接指向 creator_id-NULL 的行。
--
-- 两步：
--   1. 重定义 bootstrap_user_id —— 私有预置走克隆，公有走共享。
--   2. backfill —— 既有用户在私有预置模板上的会话/消息重新指向各自的
--      克隆副本。

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. bootstrap_user_id：私有预置 = 每用户克隆 ───────────────────────
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
end $$;

-- ── 2. backfill：既有用户的私有预置会话改指向各自克隆副本 ─────────────
DO $$
declare
  rec    record;
  tpl    record;
  new_id uuid;
begin
  for rec in
    select distinct c.user_id as uid, c.bot_id as tpl_id
      from pendingbot.conversations c
      join pendingbot.bots b on b.id = c.bot_id
     where b.creator_id is null and b.visibility = 'private'
       and c.user_id is not null
  loop
    select * into tpl from pendingbot.bots where id = rec.tpl_id;

    -- 创建（或复用）该用户对这个模板的克隆副本。
    select id into new_id from pendingbot.bots
     where slug = tpl.slug || '-' || rec.uid::text;
    if new_id is null then
      insert into pendingbot.bots
        (slug, display_name, model_id, output_mode, is_active, config,
         visibility, creator_id, created_at, updated_at)
      values
        (tpl.slug || '-' || rec.uid::text, tpl.display_name, tpl.model_id,
         tpl.output_mode, tpl.is_active, tpl.config, 'private', rec.uid,
         tpl.created_at, now())
      returning id into new_id;
    end if;

    -- 重指向：先处理用模板会话集做子查询的表（此时 conversations 还
    -- 指向模板），最后再改 conversations 本身。
    update pendingbot.messages m
       set sender_bot_id = new_id
     where m.sender_bot_id = rec.tpl_id
       and m.conversation_id in (
         select id from pendingbot.conversations
          where user_id = rec.uid and bot_id = rec.tpl_id
       );

    update pendingbot.bot_lookbacks t
       set bot_id = new_id
     where t.bot_id = rec.tpl_id
       and t.conversation_id in (
         select id from pendingbot.conversations
          where user_id = rec.uid and bot_id = rec.tpl_id
       );

    update pendingbot.conversation_participants p
       set participant_id = new_id
     where p.participant_type = 'bot'
       and p.participant_id = rec.tpl_id
       and p.conversation_id in (
         select id from pendingbot.conversations
          where user_id = rec.uid and bot_id = rec.tpl_id
       );

    -- 带 user_id 的卫星表 —— 直接按 (模板, 用户) 重指向。
    update pendingbot.bot_code_exec_requests
       set bot_id = new_id
     where bot_id = rec.tpl_id and user_id = rec.uid;
    update pendingbot.bot_user_lookback_counter
       set bot_id = new_id
     where bot_id = rec.tpl_id and user_id = rec.uid;
    update pendingbot.realtime_sessions
       set bot_id = new_id
     where bot_id = rec.tpl_id and user_id = rec.uid;
    update pendingbot.scroll_runs
       set bot_id = new_id
     where bot_id = rec.tpl_id and user_id = rec.uid;

    update pendingbot.conversations
       set bot_id = new_id
     where user_id = rec.uid and bot_id = rec.tpl_id;
  end loop;
end $$;

COMMIT;
