import type {
  ChatCompletionContentPart,
  ChatCompletionMessageParam,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { LlmStreamChunk } from './responses-adapter';

// ─────────────────────────────────────────────────────────────────────
// Anthropic native adapter.
//
// The edge LLM layer speaks the OpenAI Chat Completions dialect
// internally. Anthropic's Messages API is a different shape — and the
// whole point of routing natively (rather than through AI Gateway's
// /compat translation) is to keep provider-specific behaviour intact
// (prompt-cache control, extended thinking headroom, the real tool-use
// protocol). This module bridges the two:
//
//   • toAnthropicRequest translates a Chat-Completions-shaped request
//     into an Anthropic Messages request.
//   • openAnthropicStream POSTs it to the AI Gateway anthropic
//     passthrough on Unified Billing (cf-aig-authorization only, no
//     provider key) and re-emits the response as Chat-Completions-shaped
//     LlmStreamChunks so the bot-reply merge loop is unchanged.
//
// v1 is non-streaming: one POST, the full message mapped to a small burst
// of chunks (text, then any tool_use as tool_calls, then usage). The
// bot-reply loop accumulates deltas, so a single big delta is fine — the
// user sees the reply appear at once rather than token-by-token. True SSE
// streaming can layer on later behind the same function signature.
// ─────────────────────────────────────────────────────────────────────

// Anthropic requires max_tokens. 8192 is accepted by every current
// Claude model (some allow far more, but exceeding a model's cap is a
// 400, so we pick the universally-safe ceiling).
const ANTHROPIC_MAX_TOKENS = 8192;
const ANTHROPIC_VERSION = '2023-06-01';

interface AnthropicTextBlock {
  type: 'text';
  text: string;
}
interface AnthropicImageBlock {
  type: 'image';
  source:
    | { type: 'base64'; media_type: string; data: string }
    | { type: 'url'; url: string };
}
interface AnthropicToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  input: unknown;
}
interface AnthropicToolResultBlock {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
}
type AnthropicContentBlock =
  | AnthropicTextBlock
  | AnthropicImageBlock
  | AnthropicToolUseBlock
  | AnthropicToolResultBlock;

interface AnthropicMessage {
  role: 'user' | 'assistant';
  content: AnthropicContentBlock[];
}

interface AnthropicTool {
  name: string;
  description?: string;
  input_schema: Record<string, unknown>;
}

interface AnthropicRequest {
  model: string;
  max_tokens: number;
  system?: string;
  messages: AnthropicMessage[];
  tools?: AnthropicTool[];
}

// Pull plain text out of a Chat message content (string or block array).
function extractText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((p) =>
        p && typeof p === 'object' && (p as { type?: unknown }).type === 'text'
          ? String((p as { text?: unknown }).text ?? '')
          : '',
      )
      .join('');
  }
  return '';
}

// Turn a user/assistant content value into Anthropic content blocks,
// carrying images through as image blocks (base64 data URLs or remote
// URLs — both shapes the builder may emit).
function toContentBlocks(
  content: string | ChatCompletionContentPart[] | null | undefined,
): AnthropicContentBlock[] {
  if (typeof content === 'string') {
    return content ? [{ type: 'text', text: content }] : [];
  }
  if (!Array.isArray(content)) return [];
  const blocks: AnthropicContentBlock[] = [];
  for (const p of content) {
    if (p.type === 'text') {
      blocks.push({ type: 'text', text: p.text });
    } else if (p.type === 'image_url') {
      const url = p.image_url.url;
      const m = /^data:([^;]+);base64,(.+)$/.exec(url);
      if (m) {
        blocks.push({
          type: 'image',
          source: { type: 'base64', media_type: m[1], data: m[2] },
        });
      } else {
        blocks.push({ type: 'image', source: { type: 'url', url } });
      }
    }
  }
  return blocks;
}

// Append blocks to the running message list, merging into the previous
// message when the role matches — Anthropic rejects consecutive same-role
// turns, and tool results (which arrive as separate `tool` messages) must
// fold into a single user turn.
function pushBlocks(
  messages: AnthropicMessage[],
  role: 'user' | 'assistant',
  blocks: AnthropicContentBlock[],
): void {
  if (blocks.length === 0) return;
  const last = messages[messages.length - 1];
  if (last && last.role === role) {
    last.content.push(...blocks);
  } else {
    messages.push({ role, content: blocks });
  }
}

export function toAnthropicRequest(
  model: string,
  messages: ChatCompletionMessageParam[],
  tools: ChatCompletionTool[],
): AnthropicRequest {
  const systemParts: string[] = [];
  const out: AnthropicMessage[] = [];

  for (const m of messages) {
    if (m.role === 'system' || m.role === 'developer') {
      systemParts.push(extractText(m.content));
      continue;
    }
    if (m.role === 'user') {
      pushBlocks(out, 'user', toContentBlocks(m.content));
      continue;
    }
    if (m.role === 'assistant') {
      const blocks: AnthropicContentBlock[] = [];
      const text = extractText(m.content);
      if (text) blocks.push({ type: 'text', text });
      for (const tc of m.tool_calls ?? []) {
        if (tc.type !== 'function') continue;
        let input: unknown = {};
        try {
          input = tc.function.arguments ? JSON.parse(tc.function.arguments) : {};
        } catch {
          input = {};
        }
        blocks.push({ type: 'tool_use', id: tc.id, name: tc.function.name, input });
      }
      pushBlocks(out, 'assistant', blocks);
      continue;
    }
    if (m.role === 'tool') {
      pushBlocks(out, 'user', [
        {
          type: 'tool_result',
          tool_use_id: m.tool_call_id,
          content: extractText(m.content),
        },
      ]);
      continue;
    }
  }

  // Anthropic requires the first message to be a user turn. If the
  // transcript somehow starts with an assistant turn (shouldn't, but be
  // safe), prepend a minimal user turn so the request validates.
  if (out.length === 0 || out[0].role !== 'user') {
    out.unshift({ role: 'user', content: [{ type: 'text', text: '(continue)' }] });
  }

  const req: AnthropicRequest = {
    model,
    max_tokens: ANTHROPIC_MAX_TOKENS,
    messages: out,
  };
  const system = systemParts.filter(Boolean).join('\n\n');
  if (system) req.system = system;
  if (tools.length > 0) {
    req.tools = tools.map((t) => ({
      name: t.function.name,
      description: t.function.description,
      input_schema: (t.function.parameters as Record<string, unknown>) ?? {
        type: 'object',
        properties: {},
      },
    }));
  }
  return req;
}

interface AnthropicResponse {
  content?: Array<
    | { type: 'text'; text?: string }
    | { type: 'tool_use'; id?: string; name?: string; input?: unknown }
  >;
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    cache_read_input_tokens?: number;
    cache_creation_input_tokens?: number;
  };
  error?: { type?: string; message?: string };
}

// POST one Anthropic Messages request to the AI Gateway anthropic
// passthrough and adapt the JSON response into Chat-Completions-shaped
// chunks. Throws on a non-2xx so the router's withFallback can classify
// it (and, since this runs before any byte reaches the SSE client,
// re-resolve to another route if the error is transient).
export async function openAnthropicStream(
  baseURL: string,
  aigToken: string,
  params: {
    model: string;
    messages: ChatCompletionMessageParam[];
    tools: ChatCompletionTool[];
  },
  signal: AbortSignal,
): Promise<AsyncIterable<LlmStreamChunk>> {
  const body = toAnthropicRequest(params.model, params.messages, params.tools);
  const res = await fetch(`${baseURL}/v1/messages`, {
    method: 'POST',
    signal,
    headers: {
      'Content-Type': 'application/json',
      'anthropic-version': ANTHROPIC_VERSION,
      'cf-aig-authorization': `Bearer ${aigToken}`,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    const err = new Error(`anthropic ${res.status}: ${text}`);
    (err as { status?: number }).status = res.status;
    throw err;
  }
  const json = (await res.json()) as AnthropicResponse;
  if (json.error) {
    throw new Error(`anthropic ${json.error.type ?? 'error'}: ${json.error.message ?? ''}`);
  }
  return mapAnthropicResponse(json);
}

async function* mapAnthropicResponse(
  json: AnthropicResponse,
): AsyncGenerator<LlmStreamChunk> {
  let toolIndex = 0;
  for (const block of json.content ?? []) {
    if (block.type === 'text' && block.text) {
      yield { choices: [{ delta: { content: block.text } }] };
    } else if (block.type === 'tool_use') {
      yield {
        choices: [
          {
            delta: {
              tool_calls: [
                {
                  index: toolIndex++,
                  id: block.id,
                  function: {
                    name: block.name,
                    arguments: JSON.stringify(block.input ?? {}),
                  },
                },
              ],
            },
          },
        ],
      };
    }
  }
  const u = json.usage;
  if (u) {
    const cacheRead = u.cache_read_input_tokens ?? 0;
    yield {
      usage: {
        // usageFromCompletion treats prompt_tokens as inclusive of cache
        // reads (input = prompt - cache_read), so fold cache reads back in
        // here to recover Anthropic's separate input_tokens count.
        prompt_tokens: (u.input_tokens ?? 0) + cacheRead,
        completion_tokens: u.output_tokens ?? 0,
        cache_read_input_tokens: cacheRead,
        cache_creation_input_tokens: u.cache_creation_input_tokens ?? 0,
      },
    };
  }
}
