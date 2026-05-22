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
    /// The search query the model ran, set on `web_search` + phase
    /// 'started' when the provider surfaces it (OpenAI action.query,
    /// Anthropic server_tool_use.input.query, Gemini webSearchQueries).
    query?: string;
  };
  /// Server-side web-search results, decoupled from the tool chip because
  /// providers deliver them out of band: OpenAI streams `url_citation`
  /// annotations during the answer text (after the search "completed"),
  /// OpenRouter attaches them to the final message, Anthropic/Gemini carry
  /// them in their result blocks. The bot-reply loop folds these into the
  /// per-turn citation list and emits a `citations` SSE event.
  citations?: BuiltinCitation[];
}

/// Minimal citation shape the LLM adapters hand up to bot-reply. Kept local
/// (structurally identical to bot-reply's Citation) so the provider adapters
/// don't reach down into the bot-reply module.
export interface BuiltinCitation {
  url: string;
  title: string;
  snippet?: string;
}

// OpenAI's server-side built-in tools, added to the Responses request for
// OpenAI-native bots. The model invokes them and OpenAI runs them — no
// worker round-trip, no function-call execution. Billed through the AI
// Gateway alongside the turn.
export const OPENAI_BUILTIN_TOOLS: Tool[] = [
  { type: 'web_search_preview' },
  { type: 'code_interpreter', container: { type: 'auto' } },
  { type: 'image_generation' },
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

  // web_search built-in: the query rides the `web_search_call` output item
  // (action.query), but its result `url_citation` annotations only arrive
  // later, interleaved with the answer text. Accumulate them and flush as
  // a single citations chunk at the end so bot-reply gets one clean list.
  const webCitations: BuiltinCitation[] = [];
  const seenCitationUrls = new Set<string>();

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
        } else if (ev.item.type === 'web_search_call') {
          // The query the model decided to search for lives on the call
          // item's `action` (action.query for type 'search'). Surface the
          // 'started' chip here rather than on web_search_call.in_progress
          // so it carries the query. Read off-type — the SDK union for
          // `action` varies (search / open_page / find).
          const action = (ev.item as { action?: { query?: unknown } }).action;
          const query =
            action && typeof action.query === 'string' ? action.query : undefined;
          yield { builtinTool: { kind: 'web_search', phase: 'started', query } };
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
      // 'started' is emitted on output_item.added (above) so it carries the
      // query; in_progress would only duplicate it without one.
      case 'response.web_search_call.in_progress':
        break;
      case 'response.web_search_call.completed':
        yield { builtinTool: { kind: 'web_search', phase: 'completed' } };
        break;

      // Citation for a web_search result, attached to the answer text as it
      // streams. Dedupe by URL and buffer; flushed at response.completed.
      // (SDK 4.104.0 names this event with an underscore between text and
      // annotation; newer APIs use a dot.)
      case 'response.output_text_annotation.added': {
        const ann = (ev as { annotation?: unknown }).annotation;
        if (ann && typeof ann === 'object') {
          const a = ann as { type?: unknown; url?: unknown; title?: unknown };
          if (a.type === 'url_citation' && typeof a.url === 'string' && a.url) {
            if (!seenCitationUrls.has(a.url)) {
              seenCitationUrls.add(a.url);
              webCitations.push({
                url: a.url,
                title: typeof a.title === 'string' && a.title ? a.title : a.url,
              });
            }
          }
        }
        break;
      }
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
        if (webCitations.length > 0) {
          yield { citations: webCitations };
        }
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
