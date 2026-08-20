-- 20260522025611_arena_random_model
--
-- "随机模型 + 盲评 + 个人 leaderboard"(类 arena.ai)的数据地基。
--
-- 三块：
--   1) conversations.random_model_config —— 会话级"随机模型"开关 + 约束。
--      NULL = 不随机(走 model_slug_override / bot.model_id 的老路径)。
--      非 NULL = 每轮从满足约束的候选池里随机抽一个模型。形状:
--        { "price_min": number|null,   -- blended_usd_per_million 下界
--          "price_max": number|null,   -- 上界
--          "providers":  string[]|null } -- 厂商/来源过滤(catalog 的 provider 字段)
--      约束可单独给也可同时给; 全 null 的对象 = "全目录随机"。
--
--   2) messages.model_slug / model_provider —— 记录每条 bot 消息实际由哪个
--      模型产生。做 leaderboard 的前提:之前消息行不记模型,无法把评价归因到
--      模型。只对 bot 消息写; user/log/system 行留 NULL。
--
--   3) model_comparisons —— 每用户一套的两两胜负记录。盲评投票落一行,
--      leaderboard 端点回放这些行算 Elo。
--      "同一 prompt 的多个回答"用 messages.parent_message_id 分组,单个回答
--      的身份是 bubble_group_id —— 所以对比记录里存的是两个 bubble_group_id
--      和它们各自的模型。

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. 会话级随机模型配置 ───────────────────────────────────────────────
ALTER TABLE pendingbot.conversations
  ADD COLUMN random_model_config jsonb;

COMMENT ON COLUMN pendingbot.conversations.random_model_config IS
  '类 arena 随机模型。NULL=不随机。{price_min,price_max,providers} 约束候选池。';

-- ── 2. bot 消息记录所用模型 ─────────────────────────────────────────────
ALTER TABLE pendingbot.messages
  ADD COLUMN model_slug     text,
  ADD COLUMN model_provider text;

COMMENT ON COLUMN pendingbot.messages.model_slug IS
  '产生这条 bot 消息的模型 slug(随机模式下是当轮抽中的那个)。非 bot 行 NULL。';

-- ── 3. 个人两两胜负记录 ─────────────────────────────────────────────────
-- parent_message_id = 用户 prompt 消息; group_a/b = 两个回答的 bubble_group_id。
-- outcome: 'a' / 'b' / 'tie'。模型 slug 冗余存一份,这样 leaderboard 回放不用
-- 再回查 messages(且模型即使日后从某条消息删了,历史评价仍可解释)。
CREATE TABLE pendingbot.model_comparisons (
  id                uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id           uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  conversation_id   uuid        REFERENCES pendingbot.conversations(id) ON DELETE SET NULL,
  parent_message_id uuid,
  group_a_id        uuid        NOT NULL,
  group_b_id        uuid        NOT NULL,
  model_a           text        NOT NULL,
  model_b           text        NOT NULL,
  provider_a        text,
  provider_b        text,
  outcome           text        NOT NULL CHECK (outcome IN ('a', 'b', 'tie')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  -- 同一用户对同一对回答只记一次(再投票 = 覆盖,见 compare 端点 upsert)。
  UNIQUE (user_id, group_a_id, group_b_id)
);

CREATE INDEX model_comparisons_user_idx
  ON pendingbot.model_comparisons (user_id, created_at DESC);
CREATE INDEX model_comparisons_user_conv_idx
  ON pendingbot.model_comparisons (user_id, conversation_id);

ALTER TABLE pendingbot.model_comparisons ENABLE ROW LEVEL SECURITY;

-- 评价只读自己的。写入走 edge service_role(绕过 RLS),所以这里只给 SELECT。
CREATE POLICY model_comparisons_self_read
  ON pendingbot.model_comparisons FOR SELECT
  USING (user_id = auth.uid());

GRANT SELECT ON TABLE pendingbot.model_comparisons TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.model_comparisons TO service_role;

COMMIT;
