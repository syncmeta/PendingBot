-- 20260520020753_preset_seed_zero_unread — 预设会话初始未读为 0
--
-- 现状：bootstrap_user_id → seed_sample_dialogue 给新用户插入 6~12 条
-- 预设 bot 消息，每条都触发 update_unread_counts，使
-- user_unread_counts.unread_count 累加到 N (≥6)。
--
-- iOS 在 MessageTabView 用 last_activity_at 的年份 == 1970 作 hack 兜
-- 底，让"没人动过的预设会话"显示为已读。一旦用户在这个会话里发了第
-- 一条消息，last_activity_at 跳到现在，year 守卫失效，UI 直接读 server
-- 真实 unread_count，预设期那 N 条 bot 消息瞬间全部"翻成未读"。
--
-- 修法：把 hack 从根上拿掉。
--   1. seed_sample_dialogue 末尾把对应 user_unread_counts.unread_count
--      显式重置为 0（last_message_id/at/preview 仍指向最后一条预设消息，
--      这样列表预览不变）。
--   2. backfill：所有 last_message_at 仍在 1970 的 user_unread_counts
--      行，全部把 unread_count 归零。
--
-- iOS 的 year==1970 兜底已不再需要，伴随此迁移在客户端一并删掉。

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. 重写 seed_sample_dialogue：末尾归零 unread_count ─────────────────
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
        '按量付费 余额按调用的大模型费用计算',
        '假设想充价值 10 刀的 Token，需要付 13.86 刀，按照这个比例付',
        '另外 3.86 刀用于支付：',
        '数据库费用、账号体系管理和认证费用、云函数费用、记忆建模整理费用、开发和维护此 App 的各个 AI Agent 的费用、苹果的开发者计划费用、域名费用、邮件发送服务、我的辛苦钱、图片附件存储费用、苹果的抽成、OpenRouter 的服务费、搜索服务、网页提取服务等',
        '总体来说成本还算可控，开发者只有我一个人，不用养活一个团队、一个公司',
        '当然啊 以上只是我设想的大饼罢了 现在八字没一撇 只是沾沾当前会话中世界首富旗下的 Grok 的财气畅想一下'
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

  -- 触发器把这 N 条 bot 消息全部计入 user_unread_counts.unread_count；
  -- 预设消息是 onboarding 内容，初始就视作已读。
  update pendingbot.user_unread_counts
     set unread_count = 0
   where conversation_id = p_conv_id
     and user_id = p_user_id;
end $$;

-- ── 2. Backfill：把所有还停留在 1970 的预设会话 unread 一次性归零 ───────
UPDATE pendingbot.user_unread_counts
   SET unread_count = 0
 WHERE unread_count > 0
   AND last_message_at < '1970-01-02 00:00:00+00'::timestamptz;

COMMIT;
