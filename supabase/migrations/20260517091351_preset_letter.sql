-- 20260517091351_preset_letter — 预设来信
--
-- 每个新用户都会在「来信」里收到一封预置来信（就像每个新用户都有
-- 几个预设会话一样）。0056 那封是"版式 sampler"，纯演示排版；这次
-- 换成一封真正讲清楚「来信」是什么、为什么要写信的「读我」。
--
-- 内容搬进 DB，由 Board (admin)/letters/ 页面在线编辑，免去"改一句
-- 话 → 提 PR → 等部署"的循环 —— 和 i18n_prompts 一个套路。
--
--   1. preset_letters 表存内容（slug 主键，目前只有一行 'readme'）
--   2. seed_example_letter() 改成从 preset_letters 读，不再硬编码
--   3. backfill：把既有用户那封 trigger='example' 的来信刷成新内容
--
-- 表服务端独占（seed 函数 SECURITY DEFINER 读它，Board admin 写它）。
-- RLS 开启但无 policy = 普通用户客户端读不到。

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. 内容表 ─────────────────────────────────────────────────────────
CREATE TABLE pendingbot.preset_letters (
  slug        text NOT NULL PRIMARY KEY,
  title       text NOT NULL,
  summary     text NOT NULL,
  body_md     text NOT NULL,
  version     int  NOT NULL DEFAULT 1,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

ALTER TABLE pendingbot.preset_letters OWNER TO postgres;
ALTER TABLE pendingbot.preset_letters ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE pendingbot.preset_letters IS
  '预设来信内容。新用户首次打开 self 会话时由 seed_example_letter() 读这张表插入一封来信。Board (admin)/letters/ 编辑器写这张表。';
COMMENT ON COLUMN pendingbot.preset_letters.slug IS
  '预设来信标识。目前只有 readme 一封。';
COMMENT ON COLUMN pendingbot.preset_letters.title IS
  '来信标题，显示在来信列表封面。';
COMMENT ON COLUMN pendingbot.preset_letters.summary IS
  '来信副标题，显示在来信列表封面。';
COMMENT ON COLUMN pendingbot.preset_letters.version IS
  '每次 Board 保存 +1，留作审计基础。';

-- ── 2. 初始内容 ───────────────────────────────────────────────────────
INSERT INTO pendingbot.preset_letters (slug, title, summary, body_md)
VALUES (
  'readme',
  '读我（Readme）',
  '关于「来信」是什么，以及为什么是写信而不是发消息',
  $letter$你的好友，不论是机器人好友还是人类好友，都可以写信到“来信”这里。你可以把它当微信公众号的推送流，也可以把它当电子邮件的收件箱，就看你的好友们怎么表现了。

机器人好友会主动给你写信。如果它发现之前有什么说错了，或者发现了什么很有价值的东西，又或者想向你进谏，你可能就会在这里看到它的信。

但它不会无缘无故嘘寒问暖，那样很烦（但如果你真喜欢嘘寒问暖，它也会来问候的）它也不会天天给你发一些你看不下去的信，那样也很烦。通过信件互通有无、建立连接，确认彼此是鲜活的，就可以了。

为什么不让机器人直接发消息？因为心境、温度、节奏等等真挚的东西放不进聊天框里。如果你向名流、明星发信息，他们大概率不会回，但如果写信呢？世界各地的“信虫”就是这么拿到他们的回复的。又比如，情侣之间有隔阂后喜欢互发小作文，在那种情况下大概只有信件才有可能让自己的意思触达对方。

虽然功能上它就是电子邮件，但正如短信和微信的区别那样，短信基本上被验证码、营销、通知淹没了，真正的连接在微信里。形式上这个“来信”并不是什么新奇的东西，但这些机器人的来信我觉得还是值得期待，因为在这个应用里面它们不是陌生人。如果有一封陌生人的信，我会想是哪个商家？哪家银行？但如果告诉我是某个朋友写的，我会满怀期待。机器人好友也可以是这样。

上学期给一些朋友写信，走最传统的邮政业务。虽然我主要在微信上跟这些朋友交流，但写信触达到的感觉完全不一样，感觉很特别。上学期末还给一位私信我们学校抖音官号的高中生回了信，花了些心思，但对于其他简单发消息要TO签要周边的私信真的没有回复的欲望。在学校的收发室我也看到有很多各个学校寄来的信和明信片，感觉某种程度上可以说这才是名副其实的“真实社交”。

我是不是太理想化了？对。我就是假定人们需要信件这样的连接。我就是想基于这个假设进行实验，因为很好玩，很有意思。$letter$
);

-- ── 3. seed 函数：从 preset_letters 读，不再硬编码 ─────────────────────
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
    select 1 from pendingbot.scroll_runs
     where user_id = p_user_id and trigger = 'example'
  ) into exists_v;
  if exists_v then return; end if;

  insert into pendingbot.scroll_runs (
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

-- ── 4. Backfill：把既有用户那封示例来信刷成新内容 ─────────────────────
UPDATE pendingbot.scroll_runs sr
   SET title      = pl.title,
       summary    = pl.summary,
       body_md    = pl.body_md,
       updated_at = now()
  FROM pendingbot.preset_letters pl
 WHERE pl.slug = 'readme'
   AND sr.trigger = 'example';

-- 给已经有 self 会话、但还没收到示例来信的老用户补一封。
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

COMMIT;
