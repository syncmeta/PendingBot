import type { ChatCompletionMessageParam } from 'openai/resources/chat/completions';
import { getPrompt } from './prompt-loader';
import type { Memory } from '../lib/memory';

export interface BuildMessagesInput {
  bot: {
    id: string;
    output_mode: 'single' | 'bubble';
  };
  // Bot's own representation (Honcho passive observation) cached in KV.
  // Null on cold start — we then fall back to the identity-quest meta-prompt.
  botMemory: Memory | null;
  // Three-bucket reflections persisted from review runs (most recent first).
  // Empty on cold start; combined with botMemory drives the self section.
  reflections: Array<{ kind: 'limit' | 'grow' | 'keep'; content: string }>;
  // Recent history from the client's local cache (POST body). Already
  // ordered ascending by created_at on the client side.
  recentContext: Array<{
    role: 'user' | 'bot' | 'human' | 'log';
    content?: string | null;
    created_at: string; // ISO 8601 with timezone
  }>;
  newMessage: string;
  nowIso?: string; // override for tests
}

const BUBBLE_INSTRUCTIONS =
  '## 输出模式：bubble\n你的回复以微信气泡风格切分。每段独立成义，使用 `\\n---\\n` 分隔每个气泡。短而自然，避免段落式长句。';

const SINGLE_INSTRUCTIONS =
  '## 输出模式：single\n你的回复是一段连续的文本。不要使用气泡分隔符。可以用换行做正常排版。';

// LLM-side roles only ever see user/assistant/system. We map our wider DB
// `role` enum down: bot → assistant, user/human → user, log filtered out.
function toLlmRole(role: 'user' | 'bot' | 'human' | 'log'): 'user' | 'assistant' | null {
  if (role === 'bot') return 'assistant';
  if (role === 'user' || role === 'human') return 'user';
  return null; // logs (review/surf step entries) are not part of dialogue
}

// Two-source dialectic per plan/02: passive Honcho representation +
// reflective bot_reflections. On cold start (both empty) we hand the bot the
// identity-quest meta-prompt — a motive, not a persona.
function buildSelfSection(
  botMemory: BuildMessagesInput['botMemory'],
  reflections: BuildMessagesInput['reflections'],
): string {
  const hasMemory = !!botMemory && botMemory.representation.trim().length > 0;
  const hasReflections = reflections.length > 0;

  if (!hasMemory && !hasReflections) {
    return getPrompt('identity-quest');
  }

  const parts: string[] = [];
  if (hasMemory) {
    parts.push(
      `## How I observe myself (passive)\n${botMemory!.representation.trim()}`,
    );
  }
  if (hasReflections) {
    const grouped: Record<'limit' | 'grow' | 'keep', string[]> = {
      limit: [],
      grow: [],
      keep: [],
    };
    for (const r of reflections) grouped[r.kind].push(r.content);
    const lines: string[] = [];
    if (grouped.limit.length) lines.push(`### Limitations\n- ${grouped.limit.join('\n- ')}`);
    if (grouped.grow.length) lines.push(`### Traits to develop\n- ${grouped.grow.join('\n- ')}`);
    if (grouped.keep.length) lines.push(`### Traits to preserve\n- ${grouped.keep.join('\n- ')}`);
    parts.push(`## Things I've concluded about myself (from reflection)\n${lines.join('\n\n')}`);
  }
  if (hasMemory && hasReflections) {
    parts.push(
      '（这两份描述可能彼此矛盾——这是正常的。在矛盾中找到连贯的你。）',
    );
  }
  return parts.join('\n\n');
}

export function buildMessages(input: BuildMessagesInput): ChatCompletionMessageParam[] {
  const {
    bot,
    botMemory,
    reflections,
    recentContext,
    newMessage,
    nowIso = new Date().toISOString(),
  } = input;

  const platform = getPrompt('system');
  const selfSection = buildSelfSection(botMemory, reflections);
  const modeInstr = bot.output_mode === 'bubble' ? BUBBLE_INSTRUCTIONS : SINGLE_INSTRUCTIONS;
  const systemContent = [platform, selfSection, modeInstr].filter(Boolean).join('\n\n');

  const messages: ChatCompletionMessageParam[] = [{ role: 'system', content: systemContent }];

  // History: filter out logs, prefix each with ISO time tag (cache-friendly,
  // gives the bot temporal awareness without a dedicated "current time"
  // section in system).
  for (const m of recentContext) {
    const llmRole = toLlmRole(m.role);
    if (!llmRole) continue;
    const text = m.content ?? '';
    if (!text) continue;
    messages.push({ role: llmRole, content: `[${m.created_at}] ${text}` });
  }

  // Current user turn — also time-tagged. Lives outside the cache prefix
  // (cache breakpoint placement is a follow-up unit; for now we don't set
  // cache_control at all and let providers' implicit caching do its thing).
  messages.push({ role: 'user', content: `[${nowIso}] ${newMessage}` });

  return messages;
}
