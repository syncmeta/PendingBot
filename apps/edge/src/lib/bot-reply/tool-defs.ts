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

// OpenRouter `openrouter:web_search` configuration. Stored per-bot under
// bots.config.webSearch (camelCase), edited from the board. Maps to the
// OpenRouter server-tool `parameters` (snake_case) at build time. All
// fields optional — an absent config means "search on, engine=auto, no
// constraints", which is OpenRouter's default behaviour.
export interface WebSearchConfig {
  /// false drops the web_search tool entirely (web_fetch / datetime stay).
  /// Absent / true keeps it on.
  enabled?: boolean;
  /// auto = native provider search when available, else Exa fallback.
  engine?: 'auto' | 'native' | 'exa' | 'firecrawl' | 'parallel';
  /// Max results per search call (1–25). Ignored by native search.
  maxResults?: number;
  /// Cap on total results across every search call in one request.
  maxTotalResults?: number;
  /// Context retrieved per result (Exa) or total (Parallel). Native ignores.
  searchContextSize?: 'low' | 'medium' | 'high';
  /// Restrict results to these domains.
  allowedDomains?: string[];
  /// Drop results from these domains.
  excludedDomains?: string[];
}

// Defensively read a WebSearchConfig out of the raw bots.config jsonb.
// The PATCH /v1/bots Zod schema validates on write, but iOS can also
// write config straight through Supabase RLS, so we don't trust the shape
// blindly. Returns null when no webSearch key is present.
export function parseWebSearchConfig(config: unknown): WebSearchConfig | null {
  if (!config || typeof config !== 'object' || Array.isArray(config)) return null;
  const ws = (config as Record<string, unknown>).webSearch;
  if (!ws || typeof ws !== 'object' || Array.isArray(ws)) return null;
  const o = ws as Record<string, unknown>;
  const out: WebSearchConfig = {};
  if (typeof o.enabled === 'boolean') out.enabled = o.enabled;
  if (
    o.engine === 'auto' || o.engine === 'native' || o.engine === 'exa' ||
    o.engine === 'firecrawl' || o.engine === 'parallel'
  ) {
    out.engine = o.engine;
  }
  if (typeof o.maxResults === 'number' && Number.isFinite(o.maxResults)) {
    out.maxResults = o.maxResults;
  }
  if (typeof o.maxTotalResults === 'number' && Number.isFinite(o.maxTotalResults)) {
    out.maxTotalResults = o.maxTotalResults;
  }
  if (
    o.searchContextSize === 'low' || o.searchContextSize === 'medium' ||
    o.searchContextSize === 'high'
  ) {
    out.searchContextSize = o.searchContextSize;
  }
  if (Array.isArray(o.allowedDomains)) {
    const ds = o.allowedDomains.filter((d): d is string => typeof d === 'string' && d.length > 0);
    if (ds.length > 0) out.allowedDomains = ds;
  }
  if (Array.isArray(o.excludedDomains)) {
    const ds = o.excludedDomains.filter((d): d is string => typeof d === 'string' && d.length > 0);
    if (ds.length > 0) out.excludedDomains = ds;
  }
  return out;
}

// OpenRouter server-side tool plugins. The model decides when to call
// them; OpenRouter runs the search / fetch / clock lookup on its side and
// feeds results back — no function_call ever returns to the worker, so
// they don't go through the runTool dispatcher. Shape is OpenRouter-
// specific (not an OpenAI function tool), so callers cast at the splat
// site. web_search honours the per-bot WebSearchConfig; web_fetch and
// datetime are always on.
export function buildOpenRouterServerTools(
  webSearch?: WebSearchConfig | null,
): Array<Record<string, unknown>> {
  const tools: Array<Record<string, unknown>> = [];
  if (webSearch?.enabled !== false) {
    const params: Record<string, unknown> = {};
    if (webSearch?.engine) params.engine = webSearch.engine;
    if (webSearch?.maxResults != null) params.max_results = webSearch.maxResults;
    if (webSearch?.maxTotalResults != null) params.max_total_results = webSearch.maxTotalResults;
    if (webSearch?.searchContextSize) params.search_context_size = webSearch.searchContextSize;
    if (webSearch?.allowedDomains?.length) params.allowed_domains = webSearch.allowedDomains;
    if (webSearch?.excludedDomains?.length) params.excluded_domains = webSearch.excludedDomains;
    tools.push(
      Object.keys(params).length > 0
        ? { type: 'openrouter:web_search', parameters: params }
        : { type: 'openrouter:web_search' },
    );
  }
  tools.push({ type: 'openrouter:web_fetch' }, { type: 'openrouter:datetime' });
  return tools;
}

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
      // language question and Honcho's reasoning agent answers from the
      // bot's local model of this user (theory-of-mind). In private turns
      // it pools across every session the (bot, user) pair shares; in group
      // turns it's scoped to the current conversation so private-1v1 facts
      // don't leak into a multi-party room. Scoping lives in
      // queryUserRepresentation (lib/honcho.ts). Description in the tools
      // registry.
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
  {
    type: 'function',
    function: {
      name: 'send_images',
      // Terminal "put these pictures into the chat" tool. The bot
      // calls it with 1–5 URLs or data: URIs; the worker fetches /
      // decodes each into R2 + an attachments row, then inserts one
      // bot message carrying { attachments: { ids: […] } }. The
      // turn ends after this tool runs — there is no follow-up LLM
      // call. Description lives in pendingbot.tools.model_description
      // and is swapped in by applyToolRegistry at turn-assembly time.
      parameters: {
        type: 'object',
        properties: {
          images: {
            type: 'array',
            description: '1–5 张图片。每一项要么是 `https://...` 公网 URL，要么是 `data:image/<png|jpeg|webp|gif>;base64,<base64>` 内联数据。',
            minItems: 1,
            maxItems: 5,
            items: {
              type: 'string',
              description: 'URL 或 data: URI。单张 ≤ 25 MB。',
            },
          },
        },
        required: ['images'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'prompt_model_guess',
      // Blind-box "guess which model" card. No args. Description lives in
      // pendingbot.tools.model_description (seeded by the model_blindbox
      // migration) and is swapped in by applyToolRegistry.
      parameters: { type: 'object', properties: {}, required: [] },
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

// `delegate_to_specialist` — fire one non-streaming completion against
// an arbitrary model slug and return the answer. Always-on for every
// bot (private + public); not gated by user_bot_contacts anymore.
//
// The model picks `model_slug` based on its subscribed skills (skill
// bodies say things like "for complex math, use model='claude-opus-4.7'").
// The tool is permissive: any slug the router can resolve works; the
// fallback router surfaces upstream errors through the JSON envelope.
export const DELEGATE_TO_SPECIALIST_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'delegate_to_specialist',
    parameters: {
      type: 'object',
      properties: {
        model_slug: {
          type: 'string',
          description:
            '要委托的模型 slug（e.g. "claude-opus-4.7", "~google/gemini-2.5-pro"）。具体场景该用什么模型，看你订阅的 skill 里的说明。',
        },
        prompt: {
          type: 'string',
          description:
            '完整、自包含的任务描述 —— 专家看不到你的对话历史，必须把它需要的全部上下文、约束、产出格式都写进来。1–8000 字。',
        },
      },
      required: ['model_slug', 'prompt'],
    },
  },
};

// `ask_friend` — public bot reaches out to a named human friend with a
// self-contained question. Async by design: the tool fires off the
// outreach to the friend's 1v1 with this bot and returns immediately;
// when the bot wraps up with the friend over there, it calls
// `submit_inquiry_answer` to ship the answer back to the caller.
// Public-only; gated in bot-reply/index.ts by bots.visibility.
export const ASK_FRIEND_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'ask_friend',
    parameters: {
      type: 'object',
      properties: {
        target_display_name: {
          type: 'string',
          description:
            '要问的好友名字 —— 必须严格匹配你好友列表里某个人的 display_name（不区分大小写）。出现在本回合社交圈快照的"最近的几位"里。重名会被拒。',
        },
        question: {
          type: 'string',
          description:
            '完整、自包含的提问。这条会直接发给对方真人，对方什么时候看、什么时候回不在你掌控。1–4000 字。',
        },
      },
      required: ['target_display_name', 'question'],
    },
  },
};

// `submit_inquiry_answer` — pair tool to ask_friend. Call this from the
// relay conversation (bot ↔ friend 1v1) when you have a final answer
// to deliver back to the caller. The router picks "inject into
// caller's next turn" vs "speak up unprompted" based on caller_conv
// activity.
export const SUBMIT_INQUIRY_ANSWER_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'submit_inquiry_answer',
    parameters: {
      type: 'object',
      properties: {
        inquiry_id: {
          type: 'string',
          description:
            '要收尾的 inquiry id —— 由 ask_friend 返回时给你；如果忘了，在系统提示的"待回的好友问询"段里也会列。',
        },
        answer: {
          type: 'string',
          description:
            '要回给发起人的话。可以直接是答案正文，也可以是\"对方说不知道，需要查\"这类总结。1–6000 字。',
        },
      },
      required: ['inquiry_id', 'answer'],
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
