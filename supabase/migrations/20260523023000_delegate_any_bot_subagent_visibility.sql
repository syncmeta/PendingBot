-- Delegate-to-specialist v2:
--   - subagent conversations are readable by the owning user via normal RLS;
--   - historical subagent rows get participant rows backfilled;
--   - subagent threads stay out of unread/list state;
--   - tool registry copy reflects arbitrary bot targets, not a fixed provider trio.

BEGIN;

SET search_path TO pendingbot, public;

INSERT INTO pendingbot.conversation_participants
  (conversation_id, participant_type, participant_id, role)
SELECT c.id, 'user', c.user_id, 'owner'
  FROM pendingbot.conversations c
 WHERE c.conversation_type = 'subagent'
   AND c.user_id IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO pendingbot.conversation_participants
  (conversation_id, participant_type, participant_id, role)
SELECT c.id, 'bot', c.bot_id, 'member'
  FROM pendingbot.conversations c
 WHERE c.conversation_type = 'subagent'
   AND c.bot_id IS NOT NULL
ON CONFLICT DO NOTHING;

DELETE FROM pendingbot.user_unread_counts u
USING pendingbot.conversations c
WHERE u.conversation_id = c.id
  AND c.conversation_type = 'subagent';

UPDATE pendingbot.tools
   SET description = '把任务委托给任意可用机器人，开只读子对话；用户能看到子对话。',
       model_description = $desc$把一个具体任务委托给另一个机器人。可选目标不是固定厂商，而是你这轮工具 schema 里 `target_bot_id` 枚举列出的机器人；每个值旁边会标出显示名、模型和 provider。选择最适合任务的机器人即可，可以是 OpenRouter、OpenAI、Claude、Gemini 或其它已配置模型。

`prompt` 必须写成完整自包含的任务说明：专家看不到父对话历史，也不能继续追问用户，所以要把所有背景、约束、输入材料、判断标准和期望输出格式都写进去。子对话会持久化，用户可以点开看到完整委托过程。$desc$
 WHERE key = 'delegate_to_specialist';

COMMIT;
