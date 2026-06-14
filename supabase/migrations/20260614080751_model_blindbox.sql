-- model_blindbox
--   1) conversations.model_revealed —— 当前会话模型是否已揭示(false=显示 PendingModel)。
--      抽/重抽/换随机=false;猜中/放弃揭晓/换具体=true。仅影响显示,不影响模型选择。
--   2) model_guesses —— 持久猜测记录(每揭示一条)。
--   3) DROP model_comparisons —— 旧 A/B 盲投评价框架连根拔。
--   4) seed prompt_model_guess tool —— 否则 applyToolRegistry 会在 turn-assembly 时滤掉。

BEGIN;
SET search_path TO pendingbot, public;

ALTER TABLE pendingbot.conversations
  ADD COLUMN model_revealed boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN pendingbot.conversations.model_revealed IS
  '盲盒:当前会话模型是否已揭示。false=显示 PendingModel。抽/重抽/换随机=false;猜中/放弃/换具体=true。';

CREATE TABLE pendingbot.model_guesses (
  id              uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  conversation_id uuid        NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  actual_slug     text        NOT NULL,
  actual_provider text,
  guessed_slug    text,
  correct         boolean,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX model_guesses_user_conv_idx
  ON pendingbot.model_guesses (user_id, conversation_id, created_at DESC);
ALTER TABLE pendingbot.model_guesses ENABLE ROW LEVEL SECURITY;
CREATE POLICY model_guesses_self_read
  ON pendingbot.model_guesses FOR SELECT
  USING (user_id = auth.uid());
GRANT SELECT ON TABLE pendingbot.model_guesses TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.model_guesses TO service_role;

DROP TABLE IF EXISTS pendingbot.model_comparisons;

-- prompt_model_guess —— native 工具。kind='native' (NOT NULL + tools_kind_chk),
-- scopes 是 jsonb 数组 (列类型 jsonb,不是 text[]),native 工具必须带非空
-- model_description (tools_native_model_description_chk)。
INSERT INTO pendingbot.tools (key, kind, scopes, enabled, description, model_description)
VALUES (
  'prompt_model_guess',
  'native',
  '["chat"]'::jsonb,
  true,
  '邀请用户猜本会话背后是哪个模型,在聊天里插入一张"猜一猜"互动卡片。',
  '当你想邀请用户猜一猜本会话背后是哪个模型时调用(无参)。会在聊天里插入一张"猜一猜"互动卡片。仅在盲盒模式(用户尚未揭示)下有意义;若用户已知道模型,不要调用。'
)
ON CONFLICT (key) DO UPDATE
  SET kind = EXCLUDED.kind,
      scopes = EXCLUDED.scopes,
      enabled = EXCLUDED.enabled,
      description = EXCLUDED.description,
      model_description = EXCLUDED.model_description;

COMMIT;
