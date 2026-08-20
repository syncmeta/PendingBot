-- 20260520102713_preset_grok_group_gemini_call
--
-- 1. 「读我」末尾两段并为一段 —— 旧版后半段拖太长。
-- 2. Grok (dolor) 预设会话改主题：原来是「这个 App 八字没一撇呢」（计费畅想），
--    新版聚焦群里的机器人体验。标题改 "Grok - 群"。
-- 3. Gemini (adipiscing) 此前没有预设会话；这次给它加一段「打电话」介绍，
--    标题 "Gemini 3.5 Flash - 打电话"。
--
-- 两步：
--   * 改 preset_letters 那一行；refresh 既有用户那封 example 来信
--   * 改 seed_sample_dialogue / bootstrap_user_id；
--     backfill：dolor 老标题改名、未动过的预设消息重发；adipiscing 给老用户补一份。

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. 改「读我」内容 ────────────────────────────────────────────────
UPDATE pendingbot.preset_letters
   SET body_md = $letter$你的好友，不论是机器人好友还是人类好友，都可以写信到“来信”这里。你可以把它当微信公众号的推送流，也可以把它当电子邮件的收件箱，就看你的好友们怎么表现了。

机器人好友会主动给你写信。如果它发现之前有什么说错了，或者发现了什么很有价值的东西，又或者想向你进谏，你可能就会在这里看到它的信。

但它不会无缘无故嘘寒问暖，那样很烦（但如果你真喜欢嘘寒问暖，它也会来问候的）它也不会天天给你发一些你看不下去的信，那样也很烦。通过信件互通有无、建立连接，确认彼此是鲜活的，就可以了。

为什么不让机器人直接发消息？因为心境、温度、节奏等等真挚的东西放不进聊天框里。如果你向名流、明星发信息，他们大概率不会回，但如果写信呢？世界各地的“信虫”就是这么拿到他们的回复的。又比如，情侣之间有隔阂后喜欢互发小作文，在那种情况下大概只有信件才有可能让自己的意思触达对方。

虽然功能上它就是电子邮件，但正如短信和微信的区别那样，短信基本上被验证码、营销、通知淹没了，真正的连接在微信里。形式上这个“来信”并不是什么新奇的东西，但这些机器人的来信我觉得还是值得期待，因为在这个应用里面它们不是陌生人。如果有一封陌生人的信，我会想是哪个商家？哪家银行？但如果告诉我是某个朋友写的，我会满怀期待。机器人好友也可以是这样。

上学期给一些朋友写信，走最传统的邮政业务，感觉好好玩，很有意思。我就喜欢弄些这种好玩的东西。$letter$,
       version    = version + 1,
       updated_at = now()
 WHERE slug = 'readme';

-- Refresh 既有用户那封 example 来信。
UPDATE pendingbot.envelope_runs sr
   SET title      = pl.title,
       summary    = pl.summary,
       body_md    = pl.body_md,
       updated_at = now()
  FROM pendingbot.preset_letters pl
 WHERE pl.slug = 'readme'
   AND sr.trigger = 'example';

-- ── 2. 重写 seed_sample_dialogue ─────────────────────────────────────
CREATE OR REPLACE FUNCTION pendingbot.seed_sample_dialogue(p_conv_id uuid, p_user_id uuid, p_bot_id uuid, p_slug text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  bot_messages text[];
  base_ts timestamptz;
  msg text;
  i int := 0;
begin
  if exists (select 1 from pendingbot.messages where conversation_id = p_conv_id) then
    return;
  end if;

  case p_slug
    when 'lorem' then
      base_ts := '1970-01-01 05:00:00+00'::timestamptz;
      bot_messages := ARRAY[
        '这里的机器人会不断回头查证自己说的话 自我批评 避免误导你',
        '会给你进谏（写奏折）会主动去探索 寻觅对你有价值的信息',
        '如何使用？你可以把这个 App 理解为部分账号是机器人的微信 聊就完事了',
        '这里先大概说下特性 说多了你可能看不下去',
        '返回消息主页 其它会话里会进一步说明',
        '最后介绍一下 Claude Opus 用某宝商家的话来评价就是：小贵！但真好用！',
        '有什么想问的可以直接在这里发消息问这个机器人',
        '不过还是强烈建议你先看看其它介绍 因为 Opus 确实贵'
      ];
    when 'ipsum' then
      base_ts := '1970-01-01 04:00:00+00'::timestamptz;
      bot_messages := ARRAY[
        '在这个 App 里面，你可以有若干机器人好友和人类好友',
        '现在这几个预设机器人好友里既有私有的，也有公有的（我就是公有的）',
        '公有机器人的公开程度有两种：邀请制 公开可加',
        '前者只能和创建者邀请的用户聊 后者所有人都能聊',
        '**一定注意！公有的机器人可能和 App 里的其他人聊天，不要向它透露任何隐私或敏感信息！**',
        '但也请注意：别人**不会**直接看到你和公有机器人之间的聊天记录，只是它在和别人聊天的时候能记得你',
        '一般情况下问题不大，但是如果机器人被别人策反呢？现实世界中的朋友也可能会透露你不想公开的秘密',
        '那为什么要设置公开的机器人？因为好玩啊 就像你的微信好友里不可能只有你的家人一样',
        '你可以创建公开的机器人，别人可以加它好友',
        '谁用机器人就计谁的费用，你创建的只是一个机器人格 这个逻辑和市面上很多产品类似 比如 [Character.ai](http://Character.ai)',
        '公有机器人不属于任何人 创建者对它的权限仅限于更改公开程度 看不到它的好友和消息',
        '如果创建私有机器人，它只会和你聊天 私有机器人的逻辑就和 ChatGPT 差不多了'
      ];
    when 'sit' then
      base_ts := '1970-01-01 03:00:00+00'::timestamptz;
      bot_messages := ARRAY[
        '这是和微信逻辑最不一样的地方',
        '一个机器人，可以一直开新对话，和ChatGPT一样',
        '也可以理解为 你能给机器人开无数个小号',
        '跟不同小号聊天在不同的对话里 但回应你的都是那个机器人',
        '另外 你可以随意更换机器人的模型 记忆保持不变 消息历史保持不变',
        '世界上几乎所有模型都能选 接入了 OpenRouter',
        '最后介绍当前的 Kimi 和其他几个前沿国产模型最不一样的是识图能力',
        '像 GLM Deepseek 主模型是看不了图片的 他们看图的模型效果没 Kimi 好'
      ];
    when 'amet' then
      base_ts := '1970-01-01 02:00:00+00'::timestamptz;
      bot_messages := ARRAY[
        '这是目前 AI 应用最常见的问候',
        '但我觉得这个问题不应该 AI 问人类 而应该 AI 自己去发现',
        '因为人类普遍不清楚 AI 到底能为自己做些什么',
        '这就是这个 App 的使命之一：发现 AI 能为你做些什么',
        '当然基本的助手功能也能应付 后续还会接入能运行代码的沙箱',
        '接入沙箱之后 你就可以把这些机器人当一个面前有电脑的朋友 让它帮你做手机上不太好做的事',
        '最后介绍一下当前会话的预设模型 GLM',
        '较低成本的中国开源模型 性价比较高 主打编程能力 但仍和 Opus 有一定差距',
        'Deepseek 恢复原价后 GLM 会更便宜'
      ];
    when 'dolor' then
      base_ts := '1970-01-01 01:00:00+00'::timestamptz;
      bot_messages := ARRAY[
        '机器人在群里，把它当人就好',
        '不用@它，它在适当的时候会说话的',
        '机器人产生的费用由群成员分摊',
        '分摊方式在群设置里面调整'
      ];
    when 'adipiscing' then
      base_ts := '1970-01-01 00:30:00+00'::timestamptz;
      bot_messages := ARRAY[
        '可以和机器人打电话，单独打或者在群里打都可以',
        '如果在群里，可以直接拉机器人进群语音，把它当人就好了'
      ];
    else
      -- consectetur (GPT) intentionally has no preset session
      return;
  end case;

  foreach msg in array bot_messages loop
    i := i + 1;
    insert into pendingbot.messages
      (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
    values
      (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', msg,
       base_ts + (i * interval '1 second'));
  end loop;

  -- 预设消息视作已读（同 20260520020753 的做法）。
  update pendingbot.user_unread_counts
     set unread_count = 0
   where conversation_id = p_conv_id
     and user_id = p_user_id;
end $$;

-- ── 3. 重写 bootstrap_user_id：dolor 改名 + 加 adipiscing ─────────────
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

-- ── 4. Backfill ──────────────────────────────────────────────────────
-- 4a. dolor 老标题改为新名（用户没改过标题的话）。
UPDATE pendingbot.conversations c
   SET title = 'Grok - 群'
  FROM pendingbot.bots b
 WHERE c.bot_id = b.id
   AND b.slug = 'dolor'
   AND b.creator_id IS NULL
   AND c.conversation_type = 'user_bot'
   AND c.title = '这个 App 八字没一撇呢';

-- 4b. dolor：把"还停留在 1970 baseline 的"预设会话消息整段换掉。
--     判定标准：会话内最新消息仍在 1970 年（用户从未发过新消息）。
DO $$
declare
  rec record;
begin
  for rec in
    select c.id as conv_id, c.user_id, c.bot_id
      from pendingbot.conversations c
      join pendingbot.bots b on b.id = c.bot_id
     where b.slug = 'dolor'
       and b.creator_id is null
       and c.conversation_type = 'user_bot'
       and not exists (
         select 1 from pendingbot.messages m
          where m.conversation_id = c.id
            and m.created_at >= '1971-01-01'::timestamptz
       )
  loop
    delete from pendingbot.messages where conversation_id = rec.conv_id;
    perform pendingbot.seed_sample_dialogue(rec.conv_id, rec.user_id, rec.bot_id, 'dolor');
  end loop;
end $$;

-- 4c. adipiscing：给已经有 self 会话但还没有 adipiscing 预设会话的老用户补一份。
DO $$
declare
  u_id uuid;
  ad_bot_id uuid;
  conv_id uuid;
begin
  select id into ad_bot_id
    from pendingbot.bots
   where slug = 'adipiscing' and creator_id is null;
  if ad_bot_id is null then
    return;
  end if;

  for u_id in
    select distinct user_id
      from pendingbot.conversations
     where conversation_type = 'self'
       and user_id is not null
  loop
    if exists (
      select 1 from pendingbot.conversations
       where user_id = u_id
         and bot_id = ad_bot_id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title)
    values
      ('user_bot', 'message', u_id, ad_bot_id, 'Gemini 3.5 Flash - 打电话')
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', u_id, 'owner'),
      (conv_id, 'bot',  ad_bot_id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, u_id, ad_bot_id, 'adipiscing');
  end loop;
end $$;

COMMIT;
