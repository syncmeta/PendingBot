-- Register send_images in the runtime tools registry. The tool is
-- gated by tools_registry.applyToolRegistry; without this row the
-- assembled tool would be filtered out before reaching the model.
--
-- Scope is 'chat' only — envelope-runner doesn't deal with chat
-- messages. Description is the human-facing board copy;
-- model_description is the prompt the LLM actually sees, broken out so
-- the board operator can tune capability hints without a deploy.

INSERT INTO pendingbot.tools (key, kind, scopes, description, model_description)
VALUES (
  'send_images',
  'native',
  '["chat"]'::jsonb,
  '让机器人把图片发到对话里。接受 1–5 张图，每张可以是公网 URL 或 data: base64。不生图，只是把已有的图放进消息。',
  $desc$把 1–5 张图片放进当前会话作为机器人的消息。**不是生图工具**——这是用来把你已有/找到的图片直接发给对方看的。每张要么是公网 https URL（PNG/JPEG/WebP/GIF，≤ 25 MB），要么是 `data:image/<mime>;base64,<payload>` 内联数据。调用这个工具就等于发送了一条带图的消息，本轮到此结束，不需要再补充文字解释这条图是什么——想配文字的话，把它写在本轮 tool_call 之前的正常回复里。$desc$
)
ON CONFLICT (key) DO UPDATE SET
  kind = EXCLUDED.kind,
  scopes = EXCLUDED.scopes,
  description = EXCLUDED.description,
  model_description = EXCLUDED.model_description;
