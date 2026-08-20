-- Register `ask_friend` and `submit_inquiry_answer` in pendingbot.tools.
-- Both are 'chat' scope; applyToolRegistry in edge filters out any tool
-- not present here, so without these rows the public-bot gating in
-- bot-reply/index.ts would be moot.

BEGIN;

INSERT INTO pendingbot.tools (key, kind, scopes, description, model_description)
VALUES (
  'ask_friend',
  'native',
  '["chat"]'::jsonb,
  '公有机器人主动给自己的人类好友发消息提问 —— 异步,对方什么时候回不在机器人掌控,等机器人在那边收尾后用 submit_inquiry_answer 把答案带回来。',
  $desc$主动给你的一个人类好友发消息,问一个具体问题。**仅公有机器人可用,私有机器人没有这个工具**。

参数:
- `target_display_name`: 要问的好友的 display_name(严格匹配,不区分大小写)。要从本回合"我自己的社交圈"快照里的好友名挑。
- `question`: 完整、自包含的提问;这是会直接出现在对方对话里的文字。1–4000 字。

异步流程:
1. 调用立即返回 `{status: 'sent', inquiry_id, ...}`。当前 turn 里不会拿到对方的回答。
2. 对方真人收到后会在那个 1v1 会话里回你 —— 那是另一个 turn,你正常对答即可。
3. 等你和对方那边对话清楚、有了可以转述的答案,在**那个 relay 会话**里调 `submit_inquiry_answer(inquiry_id, answer)` 收尾。
4. submit_inquiry_answer 根据原会话的活跃度,要么把答案注入到你下一回合的提示里,要么直接以一条新消息的形式发给原对话方。

慎重:
- 别因为一点小问题就发,对方是真人,不是工具。
- 同一个 relay 会话同时只能有一个 open inquiry,重复调会被拒。$desc$
)
ON CONFLICT (key) DO UPDATE SET
  kind = EXCLUDED.kind,
  scopes = EXCLUDED.scopes,
  description = EXCLUDED.description,
  model_description = EXCLUDED.model_description;

INSERT INTO pendingbot.tools (key, kind, scopes, description, model_description)
VALUES (
  'submit_inquiry_answer',
  'native',
  '["chat"]'::jsonb,
  'ask_friend 的配对收尾工具:把跟好友聊完得到的答案投递回原会话(自动判注入 vs 主动发消息)。',
  $desc$与 `ask_friend` 配对使用 —— 把好友给你的回答带回原会话。

**只能在 relay 会话(你跟那个好友的 1v1)里调,且 caller_bot_id 必须等于你自己**。工具校验严格,误调会报错。

参数:
- `inquiry_id`: ask_friend 时给你的 id。也会出现在系统提示的"待回的好友问询"段(尚未实现时,留意 ask_friend 返回值)。
- `answer`: 要发给原会话发起人的话。可以是答案正文,也可以是"对方说不知道"这种总结。1–6000 字。

路由(系统自动判断):
- caller_conv 10s 内有新消息 → answer 进 inquiry 行的 pending 队列,你下一回合在原会话里回复时会自然带上(volatile 段注入)。不会再立即多一条消息。
- caller_conv 静默 → 直接以新的 bot-role 消息插到原会话里 + push 通知给原对话方。

调完这个工具,你就可以在 relay 会话里告诉好友"好的,我把答案转告给ta了"。$desc$
)
ON CONFLICT (key) DO UPDATE SET
  kind = EXCLUDED.kind,
  scopes = EXCLUDED.scopes,
  description = EXCLUDED.description,
  model_description = EXCLUDED.model_description;

COMMIT;
