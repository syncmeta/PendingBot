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

// `post_to_crew` — spec v2 §9.3. Session (or, in this bot-side variant,
// a captain/master bot) drops a key-milestone note onto the crew
// whiteboard. Only meaningful inside a crew conversation; outside
// crews the handler returns an error envelope.
//
// Category guidance (the LLM-facing world-model lives in
// apps/pendingcrew/Resources/Prompts/session-world-model.{zh,en}.md §8,
// canonical body in Langfuse — there is no apps/edge/prompts copy):
//   - 'progress'   — ongoing-status update
//   - 'question'   — blocking question for the crew
//   - 'milestone'  — completed-step / hand-off
export const POST_TO_CREW_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'post_to_crew',
    parameters: {
      type: 'object',
      properties: {
        content: {
          type: 'string',
          description:
            '群聊白板上的一条关键节点消息 —— 只发"我开始了 / 我完成了 / 我卡住了 / 重要发现",别发每一步 IO 日志。1–4000 字。',
        },
        category: {
          type: 'string',
          enum: ['progress', 'question', 'milestone'],
          description:
            '可选分类: progress (进度更新) / question (需要别人回答的问题) / milestone (节点完成 / 交接)。',
        },
        mentions: {
          type: 'array',
          description:
            '可选 @ 列表 —— 要定向通知谁。@session 会把这条直接投进那个 session 的信箱(让它下一轮看到);@human 仅作元数据(人在群聊里自己看,不进信箱)。不填 = 广播给全 crew。',
          items: {
            type: 'object',
            properties: {
              kind: {
                type: 'string',
                enum: ['session', 'human'],
                description: 'session = 定向某个编码 session;human = @ 某个人(纯元数据)。',
              },
              target_id: {
                type: 'string',
                description: 'kind=session 时必填:目标 session 的 id(uuid)。',
              },
            },
            required: ['kind'],
          },
        },
        reply_to: {
          type: 'string',
          description:
            '可选:你在回复哪条群聊消息的 id(uuid)。给了之后会自动 @ 那条消息的原发送者 —— 原帖是某 session 发的就投进它信箱,是人发的就把人标成收件人。',
        },
      },
      required: ['content'],
    },
  },
};

// `start_crew` — bot proposes creating a new crew (spec v2 §6.4). The
// tool does NOT actually create the crew; it drops a special log message
// (`log_kind='crew_proposal'`) into the current conversation that
// PendingBot renders as a confirmation card. Only after a human in the
// conversation taps 确认创建 does the decide endpoint call
// `create_crew_with_captain` with `captain_source='reuse_bot'` so the
// proposing bot becomes captain. This protects the user's wallet from
// hallucination — model never bypasses human sign-off.
export const START_CREW_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'start_crew',
    parameters: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description:
            '提议的 crew 名字（标题），1–80 字。会显示在确认卡片上，要让用户一眼看明白要拉的 crew 干什么。',
        },
        working_directory: {
          type: 'string',
          description:
            '可选的工作目录路径（仅本机 / peer 设备场景有意义），≤2048 字。云端 Fly machine 场景不用填。',
        },
        parent_crew_id: {
          type: 'string',
          description:
            '可选 — 如果这个新 crew 应该挂到某个已有 crew 当子 crew，给出父 crew 的 UUID。具体责任比例由用户在确认时分配。',
        },
        initial_brief: {
          type: 'string',
          description:
            '可选的初始任务简报，1–4000 字 —— 用户确认后，captain（也就是你）会以此为起点开始工作。',
        },
      },
      required: ['name'],
    },
  },
};

// `start_session` — spec §6.3.3. The crew CAPTAIN queues a coding session for
// its crew (runs claude code / codex on the crew's machine). Captain-only: the
// handler verifies this conversation is a crew and this bot is its captain.
// `brief` becomes the session's first instruction.
export const START_SESSION_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'start_session',
    description:
      '作为本 crew 的机长，派一个 coding session 去干活（跑 claude code / codex）。session 在 crew 所在机器上启动，作为成员出现在群里，并会读到群聊白板。只有机长能调。',
    parameters: {
      type: 'object',
      properties: {
        brief: {
          type: 'string',
          description: '交给这个 session 的任务（它的第一条指令），1–4000 字。要具体、可执行。',
        },
        runner: {
          type: 'string',
          enum: ['claude_code', 'codex'],
          description: '可选，用哪个 agent。默认 claude_code。',
        },
      },
      required: ['brief'],
    },
  },
};

// `create_child_crew` — spec §6.4. The crew CAPTAIN spawns a CHILD crew that
// inherits a share of this crew's responsibility (linked via crew_parent_links,
// responsibility_mode='inherit'). Captain-only: the handler verifies this
// conversation is a crew and this bot is its captain. There is no numeric split
// argument — inheritance is structural; resolve_crew_responsibility_shares walks
// the DAG to compute effective shares.
export const CREATE_CHILD_CREW_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'create_child_crew',
    description:
      '作为本 crew 的机长，拆出一个「子 crew」。子 crew 自动继承本 crew 的责任份额（不用你分百分比），适合把一块相对独立的子任务交给一个新机组去专门干。只有机长能调。',
    parameters: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: '子 crew 的名字（标题），1–80 字。要让人一眼看出这个子机组负责干什么。',
        },
        brief: {
          type: 'string',
          description: '可选，子 crew 的目标 / 职责说明，≤4000 字。仅用于你自己组织思路，不会改变责任继承。',
        },
      },
      required: ['name'],
    },
  },
};

// `recruit_temp_bot` — spec §6.4. The crew CAPTAIN pulls a TEMPORARY (ephemeral)
// bot into the crew as a non-responsibility-bearing participant
// (temporary_group_members.member_kind='ephemeral_bot'). It is NOT a registered
// bot reference — it's described by a name + optional persona / model. Captain-
// only: the handler verifies this conversation is a crew and this bot is its
// captain.
export const RECRUIT_TEMP_BOT_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'recruit_temp_bot',
    description:
      '作为本 crew 的机长，拉一个「临时 bot」进 crew 当参与者。临时 bot 不承担责任份额、不计费主体，只是个临时帮手角色。用名字 + 可选人设/模型来描述它。只有机长能调。',
    parameters: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: '临时 bot 的显示名，1–80 字。同一 crew 里不能有同名的活跃临时 bot。',
        },
        persona: {
          type: 'string',
          description: '可选，一句话人设 / 职责（例如「负责盯排期的项目助理」），≤2000 字。',
        },
        model_slug: {
          type: 'string',
          description: '可选，期望这个临时 bot 用的模型 slug（例如「claude-opus-4.7」）。≤200 字。',
        },
      },
      required: ['name'],
    },
  },
};

// `request_permission` — spec v2 §10. Agent (or captain bot acting in
// the crew context) asks for human approval before performing a
// high-risk action. Files a permission_requests row + writes a special
// card (message_kind='permission_request') onto the crew whiteboard so
// owner/admin humans can decide via the iOS/Mac card UI.
//
// In v1 this tool does NOT actually pause the agent (T4.5 peer_device
// communication is what wires that round-trip). The tool just files the
// card; the prompt-side note tells the model not to execute the
// underlying action until status flips to 'approved' in a later turn.
export const REQUEST_PERMISSION_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'request_permission',
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          description:
            '要请示批准的"高危操作"简短描述,1–400 字。会显示在卡片标题。例如「rm -rf node_modules」「向生产数据库写入」「调外部 API 付费」。',
        },
        details: {
          type: 'object',
          description:
            '可选的结构化详情(任意 jsonb 对象)。卡片会把它折叠后展示给批准人 —— 命令、路径、影响范围、为何要做。',
          additionalProperties: true,
        },
        risk_level: {
          type: 'string',
          enum: ['low', 'medium', 'high'],
          description: '风险等级,默认 medium。卡片可据此染色 / 排序。',
        },
      },
      required: ['action'],
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
