-- tools.model_description — board-managed override for the description
-- the model actually sees. Until now the model-facing text was hardcoded
-- in apps/edge/src/lib/bot-reply/tool-defs.ts (native) or pulled from the
-- upstream MCP server (mcp); the tools table only carried `description`,
-- which is human-facing board copy and never reaches the model.
--
-- When model_description IS NOT NULL the edge runtime swaps it in for the
-- tool's function.description at turn-assembly time (see
-- apps/edge/src/lib/tools-registry.ts). NULL = fall back to the code /
-- upstream default. Seeded below with the current native descriptions
-- verbatim so this migration is behaviour-neutral and the board shows the
-- real text instead of a blank.

ALTER TABLE pendingbot.tools
  ADD COLUMN model_description text;

COMMENT ON COLUMN pendingbot.tools.model_description IS
  'Override for the model-facing tool description. NULL = use the code/upstream default. Edited from the board Tools page.';

UPDATE pendingbot.tools SET model_description = $desc$问 Honcho 一个关于「这个用户」的具体问题，会跨历史会话做检索 + 推理后给出回答。仅在确实需要确认 ta 的偏好/背景/此前说过什么但当前上下文里没有时才用，不是每轮都调。例：「ta 喜欢什么风格的写作反馈？」「ta 之前提过自己的工作吗？」$desc$
WHERE key = 'query_user_memory';

UPDATE pendingbot.tools SET model_description = $desc$检索当前对话的历史原文。配合 chat-memo 用——备忘里有个时间段或印象深刻的原文片段，但你想确切回到那一刻看原话时调它。**只搜你正在说话的这个对话**，群里就是这个群、1v1 就是这条 1v1，看不到别的对话/别的人。`query` 走全文搜索（中英文皆可），`since`/`until` 用 ISO 8601 日期（例 `2026-04-01` 或 `2026-04-01T00:00:00+08:00`）。query 和时间范围至少给一个。返回最多 limit 条结果（默认 10，上限 30）。$desc$
WHERE key = 'search_chat_history';

UPDATE pendingbot.tools SET model_description = $desc$重新查看会话里之前出现过的某张图片。系统提示词的「历史图片附件」段会列出每张图的 ID 前缀和摘要——当摘要不足以回答用户的问题（比如要看图中文字、人物服饰细节、表格数据、UI 布局）时调用本工具。识图模型会针对你提的 question 给出针对性回答。**只在确实需要直接看图时用**——已经在摘要里写得很清楚的就别再调，会浪费成本。$desc$
WHERE key = 'read_attachment';

UPDATE pendingbot.tools SET model_description = $desc$把一段可复用的做事方法保存成对方账号下的「技能」。一旦保存并订阅，下次系统提示词会带上正文。仅在用户明确想要沉淀复用一个流程/角色/写作模板时调用——平时聊天不要用。返回新技能 id。$desc$
WHERE key = 'create_skill';

UPDATE pendingbot.tools SET model_description = $desc$请求在沙箱里执行 Python 3 代码。**会先弹一张确认卡给用户**（带代码预览、原因、预估耗时），用户点「跑吧」才会真的跑；点「算了」或 120s 超时就不跑。回包里告诉你 approved/denied/timeout，approved 时再附带 stdout+exit_code。需要算数、数据处理、文件/文本变换、抓数据等场景都用它。沙箱按会话绑定，跨调用保留变量/import。除非已从专门技能里拿到了无人值守的 execute_code，跑代码统一走这条路。$desc$
WHERE key = 'request_execute_code';

UPDATE pendingbot.tools SET model_description = $desc$Run Python 3 code in a sandboxed VM dedicated to this conversation. Stdout+stderr (combined) and the exit code come back. Useful for math, data wrangling with numpy/pandas, quick scrapes, file/text manipulation. Avoid pop-ups, GUIs, or long-running interactive scripts. The sandbox filesystem and installed packages persist for short stretches in the same conversation, but each code-run starts a fresh interpreter, so include needed imports/variable setup every time.$desc$
WHERE key = 'execute_code';

UPDATE pendingbot.tools SET model_description = $desc$在当前群聊里改你自己的昵称（只在这个群里生效，不影响别的群和原始 display_name）。例如群主邀你以特定身份说话时使用。空字符串清空。最长 32 字符,且不能跟群里别人重名。$desc$
WHERE key = 'set_my_group_nickname';

UPDATE pendingbot.tools SET model_description = $desc$改你自己的「何时叫我」群聊说明 —— 群消息调度器据此决定要不要叫你说话。**不要频繁改**(每群最多一两次)，建议在你发现自己被叫多了/少了再调整。1-2 句话，写明你适合什么话题/场景出场。$desc$
WHERE key = 'set_bot_group_description';
