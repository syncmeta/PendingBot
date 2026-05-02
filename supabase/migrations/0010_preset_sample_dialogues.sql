-- Sample dialogues for every preset bot, seeded into each user_bot
-- conversation so the message list isn't empty on first launch and the
-- user gets a quick taste of each bot's vibe / a nudge toward features.
--
-- Per the new conv-list rule (empty convs hidden from the message list),
-- each preset bot needs *some* messages in its conv to show up. These
-- three-turn samples (bot → user → bot) double as feature intros and
-- usage examples.
--
-- The function is idempotent: it only seeds a conv that has zero messages.

create or replace function pendingbot.seed_sample_dialogue(p_conv_id uuid, p_user_id uuid, p_bot_id uuid, p_slug text)
returns void
language plpgsql
security definer
as $$
declare
  bot_intro text;
  fake_user text;
  bot_followup text;
begin
  -- Skip if conv already has messages (real or seeded).
  if exists (select 1 from pendingbot.messages where conversation_id = p_conv_id) then
    return;
  end if;

  case p_slug
    when 'lorem' then
      bot_intro := '嗨。我是 Lorem，跑在 anthropic/claude-opus-latest。在这里和你聊天的同时，我能联网搜证，事情说不准时会自己去查。';
      fake_user := '蓝鲸的舌头有多重？';
      bot_followup := '一只成年蓝鲸的舌头大约 2.7 吨，相当于一头普通非洲象。这个数字我刚刚顺手查了证。';
    when 'ipsum' then
      bot_intro := '嗨，Ipsum 在这。我擅长写代码、读错误信息、debug。给我一段需求或者贴一段报错都行。';
      fake_user := '用 Python 写一个判断闰年的函数。';
      bot_followup := E'```python\ndef is_leap(y: int) -> bool:\n    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)\n```\n标准 Gregorian 规则：被 4 整除，被 100 整除时还得能被 400 整除。';
    when 'dolor' then
      bot_intro := 'Dolor 来了。语气直白，对热点新闻和正在发生的事情比较敏感。说事不说不准的我会自己上网找。';
      fake_user := '最近 AI 圈有什么大新闻？';
      bot_followup := '我刚扫了一圈——现在最显眼的几件：模型迭代节奏在加速、开源社区与商业前沿的差距继续缩小、Agent 落地应用开始多了。哪个方向你想深挖？';
    when 'sit' then
      bot_intro := '你好，我是 Sit。中文长文章扔给我，我能读完帮你抽要点、对比观点、列脉络。';
      fake_user := '我手头一份 30 页的研究报告读不动，怎么办？';
      bot_followup := '把内容贴给我，或者给我能读到的链接。我先压成「主张-论据-缺口」三段，你再决定深入哪一块。';
    when 'amet' then
      bot_intro := 'Amet 在。我擅长把零散的想法整理成清单、表格、流程。"帮我列下..." 这种需求最适合发给我。';
      fake_user := '帮我把今天要做的三件事拆成可执行步骤。';
      bot_followup := '把三件事告诉我，我会按「目标-子任务-时间估算-第一步」四列给你列出来。如果有阻塞依赖我也会标。';
    when 'consectetur' then
      bot_intro := '嗨，我是 Consectetur。擅长写作和创意——从一个标题想出一篇文章，或者从一句话扩展出多种风格的版本。';
      fake_user := '帮我想三个能让别人记住的产品名。';
      bot_followup := '给我一句产品在做什么，我从「偏抽象 / 偏画面感 / 偏隐喻」三个方向各给你 2-3 个候选，然后我们再筛。';
    when 'adipiscing' then
      bot_intro := '我是 Adipiscing。跑在 flash 上，反应快，适合琐碎小问题——查个词、问个时间、确认个细节。';
      fake_user := '一升水多少斤？';
      bot_followup := '1 升水 ≈ 1 公斤 = 2 斤。';
    when 'elit' then
      bot_intro := '我是 Elit。除了和你单聊，PendingBot 还有「议论」——挑几个机器人让我们私下讨论你（你匿名旁听）。要试试吗？';
      fake_user := '怎么用？';
      bot_followup := '消息列表右上 + 号 → 议论 → 选 ≥2 个机器人 + 一个题目。议论只你看得见，你随时可以匿名插话或停止。';
    else
      return;
  end case;

  -- Three turns. UUIDv7 keeps them ordered by id; created_at is set
  -- explicitly to a tight ascending sequence so the conv reads top-down
  -- as it would in real life.
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', bot_intro, now() - interval '3 minutes');
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, user_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_user_id, 'user', 'done', fake_user, now() - interval '2 minutes');
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', bot_followup, now() - interval '1 minute');
end $$;

-- Update the bootstrap function so brand-new users get the sample
-- dialogues seeded automatically alongside their conv rows.

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
      ('user_bot', 'message', p_uid, bot_row.id, bot_row.display_name)
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, bot_row.id, bot_row.slug);
  end loop;
end $$;

-- Backfill: seed dialogues into existing empty user_bot convs.
do $$
declare cv record;
begin
  for cv in
    select c.id as conv_id, c.user_id, c.bot_id, b.slug
      from pendingbot.conversations c
      join pendingbot.bots b on b.id = c.bot_id
     where c.conversation_type = 'user_bot'
       and b.is_active = true
       and not exists (
         select 1 from pendingbot.messages m where m.conversation_id = c.id
       )
  loop
    perform pendingbot.seed_sample_dialogue(cv.conv_id, cv.user_id, cv.bot_id, cv.slug);
  end loop;
end $$;
