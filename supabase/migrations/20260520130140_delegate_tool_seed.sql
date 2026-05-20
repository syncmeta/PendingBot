-- Register delegate_to_specialist in the runtime tools registry. The
-- tool is gated by tools_registry.applyToolRegistry; without this row
-- the assembled tool would be filtered out before reaching the model.
--
-- Scope is 'chat' only — envelope-runner doesn't currently model
-- multi-bot delegation. Description is the human-facing board copy;
-- model_description is the prompt the LLM actually sees, broken out so
-- the board operator can tune capability hints without a deploy.

INSERT INTO pendingbot.tools (key, kind, scopes, description, model_description)
VALUES (
  'delegate_to_specialist',
  'native',
  '["chat"]'::jsonb,
  '把任务委托给原生 API 专家机器人（Claude / OpenAI / Gemini），开子对话；用户能看到子对话。',
  $desc$把一个具体任务委托给具备原生 API 能力的专家机器人。可选 target：
- "claude"：Anthropic Claude。最强的工程/复杂推理/工具编排能力。难题、需要严谨思考、需要查 / 用工具时优先用，但价格较高，普通问题不要拿来用。
- "openai"：OpenAI。日常代办、生成图片（gpt-image-1）、文档转录、通用任务执行。要"做出来一个东西"的场景首选。
- "gemini"：Google Gemini。原生 Google Search grounding（实时信息、最新文档）+ Maps（地点/路线）+ 超长上下文（~1M token）。需要查最新资讯、本地信息、读大文件时用。

prompt 要写成完整自包含的任务说明 — 专家看不到你的对话历史，必须把所有它需要的背景、约束、产出格式都写进去。子对话会持久化，用户可以点开看到完整的委托过程。$desc$
)
ON CONFLICT (key) DO UPDATE SET
  kind = EXCLUDED.kind,
  scopes = EXCLUDED.scopes,
  description = EXCLUDED.description,
  model_description = EXCLUDED.model_description;
