import type OpenAI from 'openai';
import type {
  ChatCompletionContentPart,
  ChatCompletionMessageParam,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type {
  FunctionTool,
  ResponseInput,
  ResponseInputItem,
  ResponseStreamEvent,
  Tool,
} from 'openai/resources/responses/responses';

// ─────────────────────────────────────────────────────────────────────
// Responses API adapter.
//
// The whole edge LLM layer is built on the OpenAI Chat Completions
// dialect because every provider (OpenRouter etc.) speaks it. OpenAI's
// own native Responses API is a different request/response shape and is
// only reachable on the OpenAI-native provider (CF AI Gateway → OpenAI
// passthrough). This module bridges the two so the bot-reply agent loop
// stays provider-agnostic:
//
//   • chatMessagesToResponsesInput / chatToolsToResponsesTools translate
//     a Chat-Completions-shaped request into Responses API inputs.
//   • openResponsesStream opens a streamed `responses.create` call and
//     re-emits its event stream as Chat-Completions-shaped chunks
//     (LlmStreamChunk), so the caller's chunk-merge logic is unchanged.
//
// Scope is deliberately minimal — endpoint passthrough + OpenAI's
// automatic prompt caching + native usage/cost. No built-in tools, no
// stateful conversations, no reasoning-item carryover (store:false).
// ─────────────────────────────────────────────────────────────────────

// Chat-Completions-streaming-chunk-shaped subset the bot-reply loop
// consumes. A real `Stream<ChatCompletionChunk>` is structurally
// assignable to AsyncIterable<LlmStreamChunk>, so the Chat path needs no
// wrapper; the Responses path produces these via mapResponseStream.
export interface LlmStreamChunk {
  id?: string;
  choices?: Array<{
    delta?: {
      content?: string | null;
      tool_calls?: Array<{
        index: number;
        id?: string;
        function?: { name?: string; arguments?: string };
      }>;
    };
  }>;
  usage?: unknown;
  /// Built-in OpenAI tool activity (Responses API only). Function tools
  /// stream as `choices[].delta.tool_calls` and the bot-reply loop
  /// executes them; built-in tools (web_search / code_interpreter /
  /// image_generation) run server-side, so they surface here instead —
  /// the loop renders progress in the tool-trace UI and turns a finished
  /// image into a message.
  builtinTool?: {
    kind: 'web_search' | 'code_interpreter' | 'image_generation';
    phase: 'started' | 'completed';
    /// Base64 PNG, set on `image_generation` + phase 'completed'.
    imageBase64?: string;
  };
}

// OpenAI's server-side built-in tools, added to the Responses request for
// OpenAI-native bots. The model invokes them and OpenAI runs them — no
// worker round-trip, no function-call execution. Billed through the AI
// Gateway alongside the turn.
export const OPENAI_BUILTIN_TOOLS: Tool[] = [
  { type: 'web_search_preview' },
  { type: 'code_interpreter', container: { type: 'auto' } },
];

// Flatten Chat Completions tools ({type,function:{...}}) into Responses
// function tools (flat name/description/parameters). strict:false — our
// JSON schemas use optional fields and omit additionalProperties, which
// strict mode rejects.
export function chatToolsToResponsesTools(
  tools: ChatCompletionTool[],
): FunctionTool[] {
  return tools.map((t) => ({
    type: 'function',
    name: t.function.name,
    description: t.function.description,
    parameters: (t.function.parameters as Record<string, unknown> | undefined) ?? {},
    strict: false,
  }));
}

// Pull plain text out of a Chat message `content` field, which may be a
// bare string or the Anthropic-style content-block array the builder
// uses to attach cache_control. cache_control is dropped — OpenAI does
// automatic prefix caching, no annotation needed.
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

// Translate a user/assistant message `content` into a Responses message
// content value — a bare string for text-only turns, or an input-content
// list when the turn carries images.
function toInputContent(
  content: string | ChatCompletionContentPart[] | null | undefined,
): ResponseInputItem.Message['content'] | string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const parts: ResponseInputItem.Message['content'] = [];
  for (const p of content) {
    if (p.type === 'text') {
      parts.push({ type: 'input_text', text: p.text });
    } else if (p.type === 'image_url') {
      parts.push({
        type: 'input_image',
        image_url: p.image_url.url,
        detail: p.image_url.detail ?? 'auto',
      });
    }
  }
  return parts;
}

// Translate a Chat Completions message array into a Responses API
// request: the lone system message becomes `instructions`, everything
// else becomes `input` items. Assistant tool calls and tool results map
// to discrete function_call / function_call_output items keyed by the
// same id the model issued, so a multi-round agent loop round-trips.
export function chatMessagesToResponsesInput(
  messages: ChatCompletionMessageParam[],
): { instructions: string; input: ResponseInput } {
  const instructionParts: string[] = [];
  const input: ResponseInput = [];

  for (const m of messages) {
    if (m.role === 'system' || m.role === 'developer') {
      instructionParts.push(extractText(m.content));
      continue;
    }
    if (m.role === 'user') {
      input.push({ role: 'user', content: toInputContent(m.content) });
      continue;
    }
    if (m.role === 'assistant') {
      const text = extractText(m.content);
      if (text) input.push({ role: 'assistant', content: text });
      for (const tc of m.tool_calls ?? []) {
        if (tc.type !== 'function') continue;
        input.push({
          type: 'function_call',
          call_id: tc.id,
          name: tc.function.name,
          arguments: tc.function.arguments,
        });
      }
      continue;
    }
    if (m.role === 'tool') {
      input.push({
        type: 'function_call_output',
        call_id: m.tool_call_id,
        output: extractText(m.content),
      });
      continue;
    }
  }

  return { instructions: instructionParts.join('\n\n'), input };
}

export interface ResponsesStreamParams {
  model: string;
  instructions: string;
  input: ResponseInput;
  /// Function tools plus any built-in tools (OPENAI_BUILTIN_TOOLS).
  tools: Tool[];
}

// Open a streamed Responses API call and adapt its event stream into
// Chat-Completions-shaped chunks. Awaits `responses.create` first so a
// connection-time failure (401/429/5xx) throws to the caller — letting
// the router's withFallback re-resolve to another provider before any
// byte reaches the client.
export async function openResponsesStream(
  client: OpenAI,
  params: ResponsesStreamParams,
  signal: AbortSignal,
): Promise<AsyncIterable<LlmStreamChunk>> {
  const stream = await client.responses.create(
    {
      model: params.model,
      instructions: params.instructions || undefined,
      input: params.input,
      tools: params.tools,
      tool_choice: 'auto',
      stream: true,
      // Stateless: do not retain the response on OpenAI's side. We never
      // use previous_response_id, and not storing keeps conversation
      // content off OpenAI's servers.
      store: false,
    },
    { signal },
  );
  return mapResponseStream(stream);
}

async function* mapResponseStream(
  stream: AsyncIterable<ResponseStreamEvent>,
): AsyncGenerator<LlmStreamChunk> {
  // Responses streams function calls as discrete output items addressed
  // by item_id; Chat Completions streams them by a positional index and
  // the bot-reply loop merges on that index. Bridge id → index here.
  const itemIdToIndex = new Map<string, number>();
  let nextToolIndex = 0;

  for await (const ev of stream) {
    switch (ev.type) {
      case 'response.created':
        yield { id: ev.response.id };
        break;

      case 'response.output_text.delta':
        yield { choices: [{ delta: { content: ev.delta } }] };
        break;

      case 'response.output_item.added':
        if (ev.item.type === 'function_call') {
          const index = nextToolIndex++;
          if (ev.item.id) itemIdToIndex.set(ev.item.id, index);
          yield {
            choices: [
              {
                delta: {
                  tool_calls: [
                    {
                      index,
                      id: ev.item.call_id,
                      function: { name: ev.item.name },
                    },
                  ],
                },
              },
            ],
          };
        }
        break;

      case 'response.function_call_arguments.delta': {
        const index = itemIdToIndex.get(ev.item_id);
        if (index != null) {
          yield {
            choices: [
              {
                delta: {
                  tool_calls: [{ index, function: { arguments: ev.delta } }],
                },
              },
            ],
          };
        }
        break;
      }

      // ── Built-in server-side tools ──────────────────────────────────
      case 'response.web_search_call.in_progress':
        yield { builtinTool: { kind: 'web_search', phase: 'started' } };
        break;
      case 'response.web_search_call.completed':
        yield { builtinTool: { kind: 'web_search', phase: 'completed' } };
        break;
      case 'response.code_interpreter_call.in_progress':
        yield { builtinTool: { kind: 'code_interpreter', phase: 'started' } };
        break;
      case 'response.code_interpreter_call.completed':
        yield { builtinTool: { kind: 'code_interpreter', phase: 'completed' } };
        break;
      case 'response.image_generation_call.in_progress':
        yield { builtinTool: { kind: 'image_generation', phase: 'started' } };
        break;

      case 'response.output_item.done':
        // The finished image lands as an output item carrying the base64
        // result. (function_call items are handled on `added` above.)
        if (ev.item.type === 'image_generation_call' && ev.item.result) {
          yield {
            builtinTool: {
              kind: 'image_generation',
              phase: 'completed',
              imageBase64: ev.item.result,
            },
          };
        }
        break;

      case 'response.completed': {
        const u = ev.response.usage;
        if (u) {
          // Re-shape into the Chat Completions usage object so the
          // shared usageFromCompletion parser handles it. input_tokens
          // already includes cached tokens — matching prompt_tokens.
          yield {
            usage: {
              prompt_tokens: u.input_tokens,
              completion_tokens: u.output_tokens,
              total_tokens: u.total_tokens,
              prompt_tokens_details: {
                cached_tokens: u.input_tokens_details?.cached_tokens ?? 0,
              },
            },
          };
        }
        break;
      }

      case 'response.failed': {
        const err = ev.response.error;
        throw new Error(
          `responses stream failed: ${err?.code ?? 'unknown'} ${err?.message ?? ''}`.trim(),
        );
      }

      case 'error':
        throw new Error(
          `responses stream error: ${ev.code ?? ''} ${ev.message}`.trim(),
        );
    }
  }
}
