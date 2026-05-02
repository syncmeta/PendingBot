-- 1. Self-delete: NULL out parent_message_id before deleting messages.
--
-- pendingbot.messages.parent_message_id self-references the same table
-- without ON DELETE … so a delete of any parent fails the FK if a child
-- still points at it. Pre-clearing the column is the cheapest fix.

create or replace function pendingbot.delete_self_account()
returns void
language plpgsql
security definer
set search_path = pendingbot, public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'auth required';
  end if;

  -- Break parent chains so the row deletes don't violate the
  -- self-referential FK (pendingbot.messages_parent_message_id_fkey).
  update pendingbot.messages
     set parent_message_id = null
   where parent_message_id in (
     select id from pendingbot.messages where user_id = uid
   );

  delete from pendingbot.messages where user_id = uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = uid;
  -- Convs the user owns: NULL out parent links from any messages still
  -- in those convs (e.g. bot replies whose user_id was never set), then
  -- the conv-cascade will sweep the rest.
  update pendingbot.messages
     set parent_message_id = null
   where conversation_id in (
     select id from pendingbot.conversations where user_id = uid
   );
  delete from pendingbot.conversations where user_id = uid;

  delete from auth.users where id = uid;
end $$;

grant execute on function pendingbot.delete_self_account() to authenticated;

-- 2. Sample dialogues now use 1970 timestamps.
--
-- The user wants the seeded "intro" exchanges to feel like ancient
-- archive material — "as if I really chatted with these AIs in 1970".
-- Slot the three messages at +1s, +2s, +3s past the epoch so their
-- relative order survives.

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

  insert into pendingbot.messages
    (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', bot_intro, '1970-01-01 00:00:01+00');
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, user_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_user_id, 'user', 'done', fake_user, '1970-01-01 00:00:02+00');
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', bot_followup, '1970-01-01 00:00:03+00');
end $$;

-- 3. Backfill: rewind any existing sample-dialogue messages to 1970.
--
-- Identify them by content match against the eight known intros — those
-- strings won't appear in real conversations. Order: bot_intro = +1s,
-- fake_user = +2s, bot_followup = +3s. Then sync user_unread_counts so
-- the conv-list rows reflect the same epoch time.

with intros as (
  select unnest(array[
    '嗨。我是 Lorem，跑在 anthropic/claude-opus-latest。在这里和你聊天的同时，我能联网搜证，事情说不准时会自己去查。',
    '嗨，Ipsum 在这。我擅长写代码、读错误信息、debug。给我一段需求或者贴一段报错都行。',
    'Dolor 来了。语气直白，对热点新闻和正在发生的事情比较敏感。说事不说不准的我会自己上网找。',
    '你好，我是 Sit。中文长文章扔给我，我能读完帮你抽要点、对比观点、列脉络。',
    'Amet 在。我擅长把零散的想法整理成清单、表格、流程。"帮我列下..." 这种需求最适合发给我。',
    '嗨，我是 Consectetur。擅长写作和创意——从一个标题想出一篇文章，或者从一句话扩展出多种风格的版本。',
    '我是 Adipiscing。跑在 flash 上，反应快，适合琐碎小问题——查个词、问个时间、确认个细节。',
    '我是 Elit。除了和你单聊，PendingBot 还有「议论」——挑几个机器人让我们私下讨论你（你匿名旁听）。要试试吗？'
  ]) as content
),
fakeusers as (
  select unnest(array[
    '蓝鲸的舌头有多重？',
    '用 Python 写一个判断闰年的函数。',
    '最近 AI 圈有什么大新闻？',
    '我手头一份 30 页的研究报告读不动，怎么办？',
    '帮我把今天要做的三件事拆成可执行步骤。',
    '帮我想三个能让别人记住的产品名。',
    '一升水多少斤？',
    '怎么用？'
  ]) as content
),
followups as (
  select unnest(array[
    '一只成年蓝鲸的舌头大约 2.7 吨，相当于一头普通非洲象。这个数字我刚刚顺手查了证。',
    '1 升水 ≈ 1 公斤 = 2 斤。'
    -- (the longer follow-ups have markdown / unique punctuation; matching
    -- on intros + fake-user is enough — the followup row is the latest
    -- message in each conv so we resolve it by ordering at the end.)
  ]) as content
)
update pendingbot.messages m
   set created_at = case
     when m.content in (select content from intros) then '1970-01-01 00:00:01+00'::timestamptz
     when m.content in (select content from fakeusers) then '1970-01-01 00:00:02+00'::timestamptz
     else m.created_at
   end
 where m.content in (select content from intros)
    or m.content in (select content from fakeusers)
    or m.content in (select content from followups);

-- The remaining followup messages (markdown / multi-paragraph) we catch
-- via "all bot messages in convs that we just rewound" — for any conv
-- whose intro got rewound, drop the third bot message to +3s.
update pendingbot.messages m
   set created_at = '1970-01-01 00:00:03+00'::timestamptz
  from pendingbot.messages anchor
 where anchor.conversation_id = m.conversation_id
   and anchor.created_at = '1970-01-01 00:00:01+00'::timestamptz
   and m.role = 'bot'
   and m.created_at > '1970-01-01 00:01:00+00'::timestamptz;

-- Sync user_unread_counts: if a conv's latest message is at 1970, push
-- last_message_at + last_message_id back to that row so the conv-list
-- shows the same archival timestamp.
update pendingbot.user_unread_counts u
   set last_message_at = m.created_at,
       last_message_id = m.id,
       last_message_preview = left(coalesce(m.content, ''), 100)
  from (
    select distinct on (conversation_id)
      conversation_id, id, content, created_at
      from pendingbot.messages
     where created_at = '1970-01-01 00:00:03+00'::timestamptz
     order by conversation_id, created_at desc
  ) m
 where u.conversation_id = m.conversation_id;
