-- Collapse the dolor (Grok) preset onboarding session into a single
-- "this app is barely scaffolded yet" stub. The previous pricing
-- breakdown (按量付费 / 13.86 刀 / 大饼) overpromised — pricing isn't
-- real yet, so the session is reduced to one bot message and the
-- conversation title is renamed to match.
--
-- Title: 怎么收费？ → 这个 App 八字没一撇呢
-- Body : 6 messages → 1 message ("还在开发中 现在基本就是个骨架")
--
-- We update both the seed function (for new signups) and backfill
-- already-bootstrapped accounts so the dev/test users see the same
-- thing without re-signup. Backfill detection mirrors 0024: messages
-- whose created_at < 1970-01-02 are the preseeded ones.

BEGIN;

-- ── 1. Updated seed function (dolor branch only changes) ────────────────
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
        '还在开发中 现在基本就是个骨架'
      ];
    else
      -- consectetur (GPT) and adipiscing (Gemini) intentionally have no preset session
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
end $$;

-- ── 2. Updated bootstrap_user_id with new dolor title ───────────────────
CREATE OR REPLACE FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  bot_row record;
  conv_id uuid;
  preset_title text;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  for bot_row in
    select id, slug, display_name from pendingbot.bots
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

    if preset_title is null then
      continue;
    end if;

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
      ('user_bot', 'message', p_uid, bot_row.id, preset_title)
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, bot_row.id, bot_row.slug);
  end loop;
end $$;

-- ── 3. Backfill existing dolor preseeded conversations ──────────────────
-- For each dolor preset conv whose messages all sit in the 1970-01-01
-- preseed window, replace them with the single stub message and rename
-- the conversation. Mirrors the 0024 detection pattern (created_at <
-- 1970-01-02) so we don't touch any real user replies that landed after.
DO $$
declare
  rec record;
  conv_id uuid;
  dolor_bot_id uuid;
  base_ts timestamptz := '1970-01-01 01:00:00+00'::timestamptz;
  new_msg_id uuid;
  new_msg_at timestamptz;
  new_msg_content text := '还在开发中 现在基本就是个骨架';
begin
  for rec in
    select b.id as bot_id
      from pendingbot.bots b
     where b.creator_id is null
       and b.slug = 'dolor'
  loop
    dolor_bot_id := rec.bot_id;
    for conv_id in
      select c.id
        from pendingbot.conversations c
       where c.bot_id = dolor_bot_id
         and exists (
           select 1 from pendingbot.messages m
            where m.conversation_id = c.id
              and m.created_at < '1970-01-02 00:00:00+00'::timestamptz
         )
         -- Skip convs that have any post-preseed user/bot activity.
         -- Replacing 6 preseeded messages with 1 stub is fine on a
         -- pristine onboarding conv but would look weird if the user
         -- had already replied.
         and not exists (
           select 1 from pendingbot.messages m
            where m.conversation_id = c.id
              and m.created_at >= '1970-01-02 00:00:00+00'::timestamptz
         )
    loop
      -- Wipe the old preseeded messages (only the 1970 ones, leaves any
      -- real user replies intact).
      delete from pendingbot.messages
       where conversation_id = conv_id
         and created_at < '1970-01-02 00:00:00+00'::timestamptz;

      -- Insert the single new stub.
      new_msg_id := pendingbot.uuidv7();
      new_msg_at := base_ts + interval '1 second';
      insert into pendingbot.messages
        (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
      values
        (new_msg_id, pendingbot.uuidv7(), conv_id, dolor_bot_id, 'bot', 'done',
         new_msg_content, new_msg_at);

      -- Rename the conversation.
      update pendingbot.conversations
         set title = '这个 App 八字没一撇呢'
       where id = conv_id
         and title = '怎么收费？';

      -- Update unread-count cache so the message list preview matches.
      -- Only touch rows whose last_message_at is still in the preseed
      -- window — leaves real-reply caches alone.
      update pendingbot.user_unread_counts
         set last_message_id = new_msg_id,
             last_message_at = new_msg_at,
             last_message_preview = left(new_msg_content, 100)
       where conversation_id = conv_id
         and last_message_at < '1970-01-02 00:00:00+00'::timestamptz;
    end loop;
  end loop;
end $$;

COMMIT;
