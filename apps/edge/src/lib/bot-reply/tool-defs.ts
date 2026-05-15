import type { ChatCompletionTool } from 'openai/resources/chat/completions';

// JSON-schema descriptors for every tool the chat bot can call. Split
// from the rest of bot-reply/ because:
//   • These are pure data — no Workers runtime concerns, no imports
//     from the rest of the codebase.
//   • They're the surface area iOS / the model actually negotiates
//     against; editing a description shouldn't touch the orchestrator.
//   • Tool implementations live in tools/* alongside the runner that
//     dispatches them.
//
// Two top-level arrays are exposed:
//   CHAT_TOOLS       — default 1v1/self/user_user surface
//   GROUP_BOT_TOOLS  — additional tools dispatchGroupTurn appends when
//                      runChatTurn is called via inGroup=true.
//
// Two singletons are exposed for the code-execution path:
//   REQUEST_EXECUTE_CODE_TOOL — always-on; gates on a per-call user tap
//   EXECUTE_CODE_TOOL          — appended only when allowed_tools opts in

export const CHAT_TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'search_web',
      // The result envelope is `{ results: [{ n, url, title, snippet }], hint }`.
      // `n` is a 1-based index, stable across this turn (subsequent calls reuse
      // the same n for already-seen urls). The bot is told to cite a result by
      // dropping `[N]` inline next to whatever fact came from it; iOS reads the
      // citations array stored alongside the message and renders tappable chips.
      description: '搜索互联网。返回最多 8 条结果，每条带 url+标题+摘要+一个 1 基的 `n`。需要事实查证或了解最新信息时使用。\n\n**节制使用：先发 1–2 个查询，看回结果再决定要不要补**。不要一上来就并发铺开 3+ 条查询——后发的查询应该被前面的结果启发（换关键词、换语言、换站点），盲目广撒网既费钱又往往返回重复或不相关的内容。如果前两条已经够答题就停手；不够就再加 1–2 条更针对性的。\n\n在回复里引用某条结果时，请紧跟相关说法加 `[N]` 行内标记（N 对应结果的 n，可以连续如 `[1][3]`），客户端会把它渲染成可点击的小角标。不引用的话不要写 `[N]`。',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_url',
      description: '抓某个网页正文，返回干净 markdown（截断在 6000 字符）。一般在 search_web 看到有钩子的链接后用。',
      parameters: {
        type: 'object',
        properties: { url: { type: 'string' } },
        required: ['url'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'tavily_research',
      // Backed by Tavily's hosted MCP `tavily-search` tool (basic depth
      // to match the tavily:search row in web_tool_prices). Different
      // ranking + freshness profile than the default search_web (Brave) —
      // good fallback when Brave didn't surface what you wanted.
      description:
        'Tavily 搜索（不同于 search_web 用的 Brave）。Tavily 偏向新内容、新闻和事件，对中文小站、博客类内容覆盖也更全。**默认搜索继续走 search_web**；当 search_web 拿不到满意结果，或问题明显跟时效相关（最近一周/最新动态/事件追踪）时再切到 tavily_research。比 search_web 略贵。返回最多 8 条结果，结构和 search_web 一致（{n, url, title, snippet}），n 与本轮 citations 累积复用，引用同样用 `[N]` 行内标记。',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'exa_research',
      // Backed by Exa's hosted MCP `web_search_exa` tool. Differentiated
      // from search_web by neural/semantic ranking — finds conceptually
      // related content, not just keyword matches. Useful for academic
      // and "find articles similar in idea to X" queries.
      description:
        'Exa 语义/神经搜索。和基于关键词的 search_web 不同，它按「概念相似度」找内容——适合学术论文、研究主题、找跟某段描述意思相近的文章。例：「找跟『用 transformer 做时间序列预测』主题相关的论文」「找批评某流派思想的文章」。日常搜索（人名、品牌、新闻）继续走 search_web；只在 search_web 关键词搜不到、需要概念检索时切到这个。返回最多 8 条结果，结构和 search_web 一致。',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'query_user_memory',
      // Honcho dialectic endpoint as a tool. The bot phrases a natural-
      // language question; Honcho's reasoning agent searches everything it's
      // observed about this user across sessions and returns a grounded
      // answer. Use sparingly — each call costs and adds latency. The bot's
      // system prompt already carries the standing user-card + private note,
      // so reach for this only when those leave a real gap.
      description:
        '问 Honcho 一个关于「这个用户」的具体问题，会跨历史会话做检索 + 推理后给出回答。仅在确实需要确认 ta 的偏好/背景/此前说过什么但当前上下文里没有时才用，不是每轮都调。例：「ta 喜欢什么风格的写作反馈？」「ta 之前提过自己的工作吗？」',
      parameters: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: '关于用户的自然语言问题，1–500 字。',
          },
        },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'search_chat_history',
      // Verbatim recall of this conversation's own messages. Strictly
      // scoped to ctx.conversationId by the runner — group surfaces can
      // only search their own group's transcript; 1v1 only that 1v1 (which
      // is the entire user-bot history since user_bot convs are
      // (user, bot) one-to-one). At least one of `query` / `since` / `until`
      // must be set so the model can't just paginate the whole conv out.
      description:
        '检索当前对话的历史原文。配合 chat-memo 用——备忘里有个时间段或印象深刻的原文片段，但你想确切回到那一刻看原话时调它。**只搜你正在说话的这个对话**，群里就是这个群、1v1 就是这条 1v1，看不到别的对话/别的人。`query` 走全文搜索（中英文皆可），`since`/`until` 用 ISO 8601 日期（例 `2026-04-01` 或 `2026-04-01T00:00:00+08:00`）。query 和时间范围至少给一个。返回最多 limit 条结果（默认 10，上限 30）。',
      parameters: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: '关键词；支持空格分词、引号包住短语精确匹配（PostgreSQL websearch 语法）。可省略，只用时间范围搜。',
          },
          since: {
            type: 'string',
            description: 'ISO 8601 起始时间（含）。可省略。',
          },
          until: {
            type: 'string',
            description: 'ISO 8601 截止时间（不含）。可省略。',
          },
          limit: {
            type: 'integer',
            description: '最多返回条数。1–30，默认 10。',
          },
        },
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_attachment',
      description:
        '重新查看会话里之前出现过的某张图片。系统提示词的「历史图片附件」段会列出每张图的 ID 前缀和摘要——当摘要不足以回答用户的问题（比如要看图中文字、人物服饰细节、表格数据、UI 布局）时调用本工具。识图模型会针对你提的 question 给出针对性回答。**只在确实需要直接看图时用**——已经在摘要里写得很清楚的就别再调，会浪费成本。',
      parameters: {
        type: 'object',
        properties: {
          attachment_id: {
            type: 'string',
            description: '附件 ID（系统提示词里 [图 ID:xxxxxxxx] 的 8 位前缀，或完整 UUID）。前缀必须能在当前会话里唯一定位一张图。',
          },
          question: {
            type: 'string',
            description: '想知道关于这张图的什么。问得越具体回答越针对。例：「图中文字内容是什么」「人物穿什么衣服」「左下角的图表数据」。1–500 字。',
          },
        },
        required: ['attachment_id', 'question'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'create_skill',
      description:
        '把一段可复用的做事方法保存成对方账号下的「技能」。一旦保存并订阅，下次系统提示词会带上正文。仅在用户明确想要沉淀复用一个流程/角色/写作模板时调用——平时聊天不要用。返回新技能 id。',
      parameters: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: '小写连字符标识，1–80 字符，例如 write-haiku 或 weekly-review-coach。',
          },
          description: {
            type: 'string',
            description: '一句话告诉机器人「什么时候用这个技能」，便于以后判断是否触发。≤ 2000 字符。',
          },
          body: {
            type: 'string',
            description: '技能正文 markdown，订阅后会拼进系统提示词。≤ 64 KiB。',
          },
        },
        required: ['name', 'description', 'body'],
      },
    },
  },
];

// Frontmatter name regex — must match the DB CHECK in 0026.
export const SKILL_NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export const SKILL_NAME_MAX = 80;
export const SKILL_DESC_MAX = 2000;
export const SKILL_BODY_MAX = 65536;

// User-approval-gated code execution. Always-on. The bot calls this when
// it wants to run Python; the edge worker pauses the SSE turn, asks iOS
// to render a confirmation card (code preview + reason + ETA), and only
// runs the code once the user taps 跑吧. 算了 / timeout returns the
// decision to the model so it can pick a different approach.
export const REQUEST_EXECUTE_CODE_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'request_execute_code',
    description:
      '请求在沙箱里执行 Python 3 代码。**会先弹一张确认卡给用户**（带代码预览、原因、预估耗时），用户点「跑吧」才会真的跑；点「算了」或 120s 超时就不跑。回包里告诉你 approved/denied/timeout，approved 时再附带 stdout+exit_code。需要算数、数据处理、文件/文本变换、抓数据等场景都用它。沙箱按会话绑定，跨调用保留变量/import。除非已从专门技能里拿到了无人值守的 execute_code，跑代码统一走这条路。',
    parameters: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'Python 3 源码。沙箱预装 numpy/pandas/matplotlib/pillow/requests/httpx/python-dateutil。',
        },
        reason: {
          type: 'string',
          description: '一句话告诉用户「为什么需要跑这段代码」，会显示在确认卡上，让用户能快速判断要不要批准。中文。',
        },
        estimated_seconds: {
          type: 'integer',
          description: '预估执行耗时（秒）。给用户一个等待预期，普通脚本 1–10 秒就够；最大 600。',
        },
      },
      required: ['code', 'reason', 'estimated_seconds'],
    },
  },
};

// Sensitive tools — appended to the per-turn tools list only when the
// active skill set's frontmatter.allowed_tools opts the user in. The same
// gating model Anthropic Skills uses to keep code-exec out of every chat.
// This is the unsupervised path: kept around for power users who explicitly
// subscribe a skill that grants `allowed_tools: [execute_code]`. Default
// users only see request_execute_code (which gates on a per-call user tap).
export const EXECUTE_CODE_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'execute_code',
    description:
      'Run Python 3 code in a sandboxed VM dedicated to this conversation. Stdout+stderr (combined) and the exit code come back. Useful for math, data wrangling with numpy/pandas, quick scrapes, file/text manipulation. Avoid pop-ups, GUIs, or long-running interactive scripts. The sandbox filesystem and installed packages persist for short stretches in the same conversation, but each code-run starts a fresh interpreter, so include needed imports/variable setup every time.',
    parameters: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'Python source. Will be executed via Daytona\'s code-run; uses the system python with numpy/pandas/matplotlib/pillow/requests/httpx/python-dateutil pre-installed.',
        },
      },
      required: ['code'],
    },
  },
};

// Group-only tools — exposed by dispatchGroupTurn via input.inGroup.
// Both write to the same conversation_id + bot_id the runner is acting
// for, so they take just the new value as an argument. Description
// edits should be rare (the system prompt says so); the runner does
// not rate-limit them — abuse would show up as audit_log spam.
export const GROUP_BOT_TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'set_my_group_nickname',
      description:
        '在当前群聊里改你自己的昵称（只在这个群里生效，不影响别的群和原始 display_name）。例如群主邀你以特定身份说话时使用。空字符串清空。最长 32 字符,且不能跟群里别人重名。',
      parameters: {
        type: 'object',
        properties: {
          nickname: { type: 'string' },
        },
        required: ['nickname'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'set_bot_group_description',
      description:
        '改你自己的「何时叫我」群聊说明 —— 群消息调度器据此决定要不要叫你说话。**不要频繁改**(每群最多一两次)，建议在你发现自己被叫多了/少了再调整。1-2 句话，写明你适合什么话题/场景出场。',
      parameters: {
        type: 'object',
        properties: {
          description: { type: 'string' },
        },
        required: ['description'],
      },
    },
  },
];
