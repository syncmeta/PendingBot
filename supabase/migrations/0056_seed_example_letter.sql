-- 0056_seed_example_letter — preload one ready-made 来信 in every user's
-- 来信 tab so the format / typography is visible even before any bot has
-- written something for real.
--
-- The seed letter is "from the user themselves" — attributed to the
-- per-user self-bot (slug = 'self-' || user_id), whose display_name is
-- the user's own name. Its body is a markdown sampler so we can eyeball
-- spacing, headings, lists, blockquotes, code, tables in one shot.
--
-- Idempotent on two layers:
--   1) helper function checks for an existing row with trigger='example'
--      before inserting, so re-running is a no-op
--   2) we patch open_self_conv to call the helper at the end, so new
--      users get the seed automatically when their self-conv first opens

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. Seed helper ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pendingbot.seed_example_letter(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  bot_id_v   uuid;
  conv_id_v  uuid;
  bot_slug_v text;
  body_md_v  text;
  exists_v   boolean;
begin
  if p_user_id is null then return; end if;

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
    select 1 from pendingbot.scroll_runs
     where user_id = p_user_id and trigger = 'example'
  ) into exists_v;
  if exists_v then return; end if;

  body_md_v := E'这是一封预置的示例来信，目的是让你看一眼"来信"的版式：标题、副标题、正文之间的留白，行距，字号，配色。\n\n'
            || E'## 二级标题长这样\n\n'
            || E'正文第一段会显示成这种字号。**加粗**、*斜体*、`行内代码`、[外链](https://pendingname.com) 都顺带测一下，看看排在一起读不读得顺。机器人写真实的来信时，引用资料会用 [1](https://example.com) 这种内联链接的格式。\n\n'
            || E'### 三级标题再小一点\n\n'
            || E'下面是一段无序列表：\n\n'
            || E'- 第一项\n'
            || E'- 第二项里夹一段更长的话，看看换到第二行之后行距够不够、读起来累不累\n'
            || E'- 第三项\n\n'
            || E'再来一段有序的：\n\n'
            || E'1. 先做这个\n'
            || E'2. 再做那个\n'
            || E'3. 最后收尾\n\n'
            || E'> 这是一段引用。机器人写来信的时候，偶尔会引你之前说过的话，或者它自己上一封信里的判断，用来做对照。\n\n'
            || E'代码块——等宽字体，带复制按钮：\n\n'
            || E'```js\n'
            || E'function greet(name) {\n'
            || E'  return `你好，${name}`;\n'
            || E'}\n'
            || E'```\n\n'
            || E'还有表格：\n\n'
            || E'| 项目 | 说明 | 备注 |\n'
            || E'| --- | --- | --- |\n'
            || E'| 标题 | 不超过 24 字符 | 越短越好 |\n'
            || E'| 副标题 | 不超过 60 字符 | 显示在列表封面 |\n'
            || E'| 正文 | 几百到一千多字 | 重点是密度 |\n\n'
            || E'## 关于这封信\n\n'
            || E'- 这封信是 App 自动放进来的，让你提前看一眼版式。\n'
            || E'- 真的来信会按时间倒序排，新写的盖在旧的上面。\n'
            || E'- 等你和某个机器人聊到一定程度，去会话设置里点"请这位写一封来信"，它就会去翻你们的聊天记录、上网查证，然后给你写一封。\n';

  insert into pendingbot.scroll_runs (
    user_id, bot_id, conversation_id,
    status, title, summary, body_md,
    trigger, started_at, finished_at
  )
  values (
    p_user_id, bot_id_v, conv_id_v,
    'done',
    '示例来信：先看一眼版式',
    '这是一封占位的来信，让你看看标题、副标题、正文摆在一起的样子。',
    body_md_v,
    'example',
    now(),
    now()
  );
end $$;

ALTER FUNCTION pendingbot.seed_example_letter(uuid) OWNER TO postgres;

-- ── 2. Backfill: seed every existing self-conv user ──────────────────
DO $$
declare
  u_id uuid;
begin
  for u_id in
    select distinct user_id
      from pendingbot.conversations
     where conversation_type = 'self'
  loop
    perform pendingbot.seed_example_letter(u_id);
  end loop;
end $$;

-- ── 3. Patch open_self_conv to seed on first call ────────────────────
CREATE OR REPLACE FUNCTION pendingbot.open_self_conv() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id   uuid := auth.uid();
  bot_uuid    uuid;
  conv_id     uuid;
  caller_name text;
  bot_slug    text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  bot_slug := 'self-' || caller_id::text;

  select coalesce(nullif(display_name, ''), '你') into caller_name
    from pendingbot.users where id = caller_id;

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
       caller_id,
       'private',
       true)
    returning id into bot_uuid;
  end if;

  -- Reuse if a self conv already exists.
  select id into conv_id
    from pendingbot.conversations
   where user_id = caller_id and conversation_type = 'self'
   limit 1;
  if conv_id is not null then
    perform pendingbot.seed_example_letter(caller_id);
    return conv_id;
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('self', 'message', caller_id, bot_uuid, coalesce(caller_name, '我自己'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  bot_uuid,  'member');

  perform pendingbot.seed_example_letter(caller_id);

  return conv_id;
end $$;

ALTER FUNCTION pendingbot.open_self_conv() OWNER TO postgres;

COMMIT;
