import { randomUUID } from 'node:crypto';
import type {
  ChatCompletionContentPart,
  ChatCompletionMessageParam,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { BuiltinCitation, LlmStreamChunk } from './responses-adapter';

// ─────────────────────────────────────────────────────────────────────
// Gemini (Google AI Studio) native adapter.
//
// Same role as anthropic-adapter.ts: bridge the internal Chat
// Completions dialect to Gemini's native generateContent shape so the
// provider-specific features (Google Search grounding, Maps, the real
// function-calling protocol, 1M-token context) survive — which AI
// Gateway's /compat translation would flatten away.
//
// Routes through the AI Gateway google-ai-studio passthrough on Unified
// Billing (cf-aig-authorization only, no provider key). v1 is
// non-streaming: one generateContent POST mapped to a small burst of
// LlmStreamChunks; the bot-reply loop accumulates deltas all the same.
// ─────────────────────────────────────────────────────────────────────

interface GeminiPart {
  text?: string;
  inlineData?: { mimeType: string; data: string };
  functionCall?: { name: string; args: Record<string, unknown> };
  functionResponse?: { name: string; response: Record<string, unknown> };
}
interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}
interface GeminiFnTool {
  functionDeclarations: Array<{
    name: string;
    description?: string;
    parameters?: Record<string, unknown>;
  }>;
}
// Built-in Google Search grounding. Empty config object enables it; the
// model decides when to search and returns sources in groundingMetadata.
interface GeminiSearchTool {
  google_search: Record<string, never>;
}
type GeminiTool = GeminiFnTool | GeminiSearchTool;
interface GeminiRequest {
  systemInstruction?: { parts: GeminiPart[] };
  contents: GeminiContent[];
  tools?: GeminiTool[];
}

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

function toParts(
  content: string | ChatCompletionContentPart[] | null | undefined,
): GeminiPart[] {
  if (typeof content === 'string') return content ? [{ text: content }] : [];
  if (!Array.isArray(content)) return [];
  const parts: GeminiPart[] = [];
  for (const p of content) {
    if (p.type === 'text') {
      parts.push({ text: p.text });
    } else if (p.type === 'image_url') {
      const m = /^data:([^;]+);base64,(.+)$/.exec(p.image_url.url);
      // Gemini inlineData only takes base64 bytes — remote URLs aren't
      // supported on generateContent, so a non-data URL image is dropped
      // (the builder normally inlines images as data URLs anyway).
      if (m) parts.push({ inlineData: { mimeType: m[1], data: m[2] } });
    }
  }
  return parts;
}

function pushContent(
  contents: GeminiContent[],
  role: 'user' | 'model',
  parts: GeminiPart[],
): void {
  if (parts.length === 0) return;
  const last = contents[contents.length - 1];
  if (last && last.role === role) {
    last.parts.push(...parts);
  } else {
    contents.push({ role, parts });
  }
}

function parseObject(s: string | undefined): Record<string, unknown> {
  if (!s) return {};
  try {
    const v = JSON.parse(s);
    return v && typeof v === 'object' && !Array.isArray(v)
      ? (v as Record<string, unknown>)
      : { value: v };
  } catch {
    return {};
  }
}

export function toGeminiRequest(
  messages: ChatCompletionMessageParam[],
  tools: ChatCompletionTool[],
  webSearch?: boolean,
): GeminiRequest {
  const systemParts: GeminiPart[] = [];
  const contents: GeminiContent[] = [];
  // Gemini's functionResponse keys by function NAME, but the Chat `tool`
  // message only carries tool_call_id — so track id→name from the
  // assistant tool_calls as we walk the transcript.
  const idToName = new Map<string, string>();

  for (const m of messages) {
    if (m.role === 'system' || m.role === 'developer') {
      const t = extractText(m.content);
      if (t) systemParts.push({ text: t });
      continue;
    }
    if (m.role === 'user') {
      pushContent(contents, 'user', toParts(m.content));
      continue;
    }
    if (m.role === 'assistant') {
      const parts: GeminiPart[] = [];
      const text = extractText(m.content);
      if (text) parts.push({ text });
      for (const tc of m.tool_calls ?? []) {
        if (tc.type !== 'function') continue;
        idToName.set(tc.id, tc.function.name);
        parts.push({
          functionCall: {
            name: tc.function.name,
            args: parseObject(tc.function.arguments),
          },
        });
      }
      pushContent(contents, 'model', parts);
      continue;
    }
    if (m.role === 'tool') {
      const name = idToName.get(m.tool_call_id) ?? m.tool_call_id;
      pushContent(contents, 'user', [
        {
          functionResponse: {
            name,
            response: parseObject(extractText(m.content)),
          },
        },
      ]);
      continue;
    }
  }

  if (contents.length === 0 || contents[0].role !== 'user') {
    contents.unshift({ role: 'user', parts: [{ text: '(continue)' }] });
  }

  const req: GeminiRequest = { contents };
  if (systemParts.length > 0) req.systemInstruction = { parts: systemParts };
  const toolEntries: GeminiTool[] = [];
  if (tools.length > 0) {
    toolEntries.push({
      functionDeclarations: tools.map((t) => ({
        name: t.function.name,
        description: t.function.description,
        parameters: (t.function.parameters as Record<string, unknown>) ?? {
          type: 'object',
          properties: {},
        },
      })),
    });
  }
  // Google Search grounding rides as its own tools entry alongside the
  // function declarations. Gemini 2.x/3.x support search + function calling
  // in one request; older models reject the combination.
  if (webSearch) toolEntries.push({ google_search: {} });
  if (toolEntries.length > 0) req.tools = toolEntries;
  return req;
}

interface GeminiGroundingMetadata {
  // The actual query strings the model searched for.
  webSearchQueries?: string[];
  // The sources it grounded on; web.uri / web.title are the link + label.
  groundingChunks?: Array<{ web?: { uri?: string; title?: string } }>;
}
interface GeminiResponse {
  candidates?: Array<{
    content?: { parts?: GeminiPart[] };
    groundingMetadata?: GeminiGroundingMetadata;
  }>;
  usageMetadata?: {
    promptTokenCount?: number;
    candidatesTokenCount?: number;
    cachedContentTokenCount?: number;
  };
  error?: { status?: string; message?: string };
}

function isSearchFunctionToolConflict(
  status: number,
  body: string,
  params: { tools: ChatCompletionTool[]; webSearch?: boolean },
): boolean {
  if (status !== 400 || !params.webSearch || params.tools.length === 0) return false;
  return /google_search|functionDeclarations|function calling|tool/i.test(body) &&
    /unsupported|not supported|cannot|invalid|unknown|combination/i.test(body);
}

// POST one generateContent request to the AI Gateway google-ai-studio
// passthrough and adapt the JSON response into Chat-Completions-shaped
// chunks. Throws on non-2xx so withFallback can classify + re-resolve.
export async function openGeminiStream(
  baseURL: string,
  aigToken: string,
  params: {
    model: string;
    messages: ChatCompletionMessageParam[];
    tools: ChatCompletionTool[];
    webSearch?: boolean;
  },
  signal: AbortSignal,
  // BYOK key alias → cf-aig-byok-alias header. Gemini 3.x isn't on the
  // gateway's Unified Billing native passthrough, so Google rides a stored
  // BYOK key; a non-`default` alias must be named explicitly or the
  // gateway forwards keyless and Google answers 403 "unregistered callers".
  byokAlias?: string,
): Promise<AsyncIterable<LlmStreamChunk>> {
  let body = toGeminiRequest(params.messages, params.tools, params.webSearch);
  // Must be `/v1beta/…`, NOT `/v1/…`: Google's stable `v1`
  // generateContent proto has no `systemInstruction` / `tools` fields and
  // rejects them ("Unknown name … Cannot find field"). Those live on
  // `v1beta`. Auth is cf-aig-authorization alone (Unified Billing — the
  // gateway injects the upstream key); do NOT also send x-goog-api-key,
  // the gateway forwards it upstream and Google rejects it as invalid.
  const url = `${baseURL}/v1beta/models/${params.model}:generateContent`;
  let res = await fetch(url, {
    method: 'POST',
    signal,
    headers: {
      'Content-Type': 'application/json',
      'cf-aig-authorization': `Bearer ${aigToken}`,
      ...(byokAlias ? { 'cf-aig-byok-alias': byokAlias } : {}),
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    if (isSearchFunctionToolConflict(res.status, text, params)) {
      body = toGeminiRequest(params.messages, [], params.webSearch);
      res = await fetch(url, {
        method: 'POST',
        signal,
        headers: {
          'Content-Type': 'application/json',
          'cf-aig-authorization': `Bearer ${aigToken}`,
          ...(byokAlias ? { 'cf-aig-byok-alias': byokAlias } : {}),
        },
        body: JSON.stringify(body),
      });
      if (res.ok) {
        const json = (await res.json()) as GeminiResponse;
        if (json.error) {
          throw new Error(`gemini ${json.error.status ?? 'error'}: ${json.error.message ?? ''}`);
        }
        return mapGeminiResponse(json);
      }
    }
    const err = new Error(`gemini ${res.status}: ${text}`);
    (err as { status?: number }).status = res.status;
    throw err;
  }
  const json = (await res.json()) as GeminiResponse;
  if (json.error) {
    throw new Error(`gemini ${json.error.status ?? 'error'}: ${json.error.message ?? ''}`);
  }
  return mapGeminiResponse(json);
}

async function* mapGeminiResponse(
  json: GeminiResponse,
): AsyncGenerator<LlmStreamChunk> {
  const candidate = json.candidates?.[0];
  const parts = candidate?.content?.parts ?? [];

  // Google Search grounding: surface the queries the model ran and the
  // sources it grounded on. groundingMetadata sits on the candidate, beside
  // the content parts — emit the search chip + citations before the answer
  // text so the trace ordering reads naturally.
  const grounding = candidate?.groundingMetadata;
  if (grounding && (grounding.webSearchQueries?.length || grounding.groundingChunks?.length)) {
    const query = grounding.webSearchQueries?.filter((q) => q).join(' / ') || undefined;
    yield { builtinTool: { kind: 'web_search', phase: 'started', query } };
    yield { builtinTool: { kind: 'web_search', phase: 'completed' } };
    const citations: BuiltinCitation[] = [];
    for (const chunk of grounding.groundingChunks ?? []) {
      const url = chunk.web?.uri;
      if (typeof url === 'string' && url) {
        citations.push({ url, title: chunk.web?.title || url });
      }
    }
    if (citations.length > 0) yield { citations };
  }

  let toolIndex = 0;
  for (const part of parts) {
    if (part.text) {
      yield { choices: [{ delta: { content: part.text } }] };
    } else if (part.functionCall) {
      yield {
        choices: [
          {
            delta: {
              tool_calls: [
                {
                  index: toolIndex++,
                  // Gemini function calls carry no id; synthesise a unique
                  // one so the bot-reply loop can pair the tool result.
                  id: `gemini-${randomUUID()}`,
                  function: {
                    name: part.functionCall.name,
                    arguments: JSON.stringify(part.functionCall.args ?? {}),
                  },
                },
              ],
            },
          },
        ],
      };
    }
  }
  const u = json.usageMetadata;
  if (u) {
    const cached = u.cachedContentTokenCount ?? 0;
    yield {
      usage: {
        // promptTokenCount already includes cached tokens; matches the
        // prompt_tokens convention usageFromCompletion expects.
        prompt_tokens: u.promptTokenCount ?? 0,
        completion_tokens: u.candidatesTokenCount ?? 0,
        prompt_tokens_details: { cached_tokens: cached },
      },
    };
  }
}
