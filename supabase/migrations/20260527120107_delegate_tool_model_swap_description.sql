-- Update the tools registry row for `delegate_to_specialist` to match
-- its new semantics: it is no longer "ask another bot via a sub-conv"
-- — it now fires one non-streaming completion against an arbitrary
-- model_slug and returns the answer. No bot lookup, no sub-conv, no
-- dependence on user_bot_contacts (so private bots can use it too).
--
-- Pure description swap: the registry row's `key`, `kind`, `scopes`
-- stay; only `description` (operator-facing copy on the board) and
-- `model_description` (the prompt the LLM actually reads) change.

BEGIN;

UPDATE pendingbot.tools
SET
  description = '换一个模型问一次：把自包含的问题发给指定 model_slug，拿一段答案回来。一次性、非流式，不开子对话。',
  model_description = $desc$把当前对话里的一个具体问题，换一个更大/更擅长某事的模型问一次。一次性 completion，不留子对话，不接续对话历史。

参数：
- `model_slug`：要委托的模型 slug（e.g. "claude-opus-4.7", "~google/gemini-2.5-pro"）。具体什么场景用什么 slug，看你订阅的 skill 里的说明 —— 通常某个领域 skill 会写明"复杂数学问题用 X""超长上下文用 Y"之类。
- `prompt`：完整、自包含的任务描述。专家看不到你的对话历史，必须把它需要的全部背景、约束、产出格式都写进来。1–8000 字。

注意：
- 这不是"找另一个机器人"，是换一个模型。专家没有人格、没有上下文，纯模型一次。
- 私有和公有机器人都可以用。
- 想问"我的好友怎么看"，用 ask_friend（仅公有机器人）。$desc$
WHERE key = 'delegate_to_specialist';

COMMIT;
