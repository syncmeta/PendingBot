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
// NOTE: the model-facing `function.description` is NOT defined here.
// It's the single source of truth in pendingbot.tools.model_description
// and gets swapped in at turn-assembly time by applyToolRegistry
// (apps/edge/src/lib/tools-registry.ts). Edit it from the board Tools
// page. Only the tool name + parameter schema live in code.
//
// Two top-level arrays are exposed:
//   CHAT_TOOLS       — default 1v1/self/user_user surface
//   GROUP_BOT_TOOLS  — additional tools dispatchGroupTurn appends when
//                      runChatTurn is called via inGroup=true.
//
// Two singletons are exposed for the code-execution path:
//   REQUEST_EXECUTE_CODE_TOOL — always-on; gates on a per-call user tap
//   EXECUTE_CODE_TOOL          — appended only when allowed_tools opts in

// Web search/scrape tools moved out of this static list. They now come
// from the MCP client (apps/edge/src/mcp/client.ts), which talks to Exa's
// hosted MCP server. bot-reply merges that dynamic list with these
// internal-only entries at turn assembly time.
export const CHAT_TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'query_user_memory',
      // Honcho dialectic endpoint as a tool — the bot phrases a natural-
      // language question and Honcho's reasoning agent searches everything
      // it's observed about this user across sessions. Description in the
      // tools registry.
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
      parameters: {
        type: 'object',
        properties: {
          attachment_id: {
            type: 'string',
            description: '附件 ID（系统提示词里 [图 ID:xxxxxxxx] 或 [文件 ID:xxxxxxxx] 的 8 位前缀，或完整 UUID）。前缀必须能在当前会话里唯一定位一个附件。',
          },
          question: {
            type: 'string',
            description: '想从这个附件里得到什么。图片/PDF 会按问题解析，问得越具体越好（例：「图中文字内容是什么」「这份文件的结论是什么」）；其它文本类文件会原样返回内容，问题仅作参考。1–500 字。',
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
    parameters: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'Python source. Runs in this conversation\'s Cloudflare sandbox container; uses the system python with numpy/pandas/matplotlib/pillow/requests/httpx/python-dateutil pre-installed.',
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
