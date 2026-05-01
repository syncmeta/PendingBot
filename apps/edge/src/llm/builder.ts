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
  // Skills the user has subscribed (globally and/or for this conv). Each
  // contributes a `## Skill: ...` block to system content.
  skills: Array<{ name: string; description: string; body: string }>;
  // Recent history from the client's local cache (POST body). Already
  // ordered ascending by created_at on the client side.
  recentContext: Array<{
    role: 'user' | 'bot' | 'human' | 'log';
    content?: string | null;
    created_at: string; // ISO 8601 with timezone
  }>;
  newMessage: string;
  nowIso?: string; // override for tests
  // Anthropic prompt caching: where to drop the cache_control breakpoint.
  // The plan/02 strategy is "every N=4 rounds move the breakpoint to the
  // newer end of history" — between cache writes we just hit-and-read the
  // existing prefix. Caller computes the round count and chooses the
  // breakpoint per CACHE_REFRESH_EVERY policy in this file.
  cacheBreakpointHistoryIndex?: number;
}

// How many rounds (each = one user msg + one bot reply) to keep the cache
// breakpoint stationary before it slides. Bigger = fewer cache writes (each
// write costs 1.25× input price for that segment) but stale tail gets bigger.
// 4 is the plan/02 default; tune via metrics later.
export const CACHE_REFRESH_EVERY = 4;

// Compute the breakpoint index given total history length (number of LLM-role
// messages, not raw recentContext). Returns -1 to mean "no breakpoint".
//   pattern: place breakpoint on the most recent message that's a multiple
//   of CACHE_REFRESH_EVERY*2 (×2 because round=2 messages).
export function computeCacheBreakpoint(historyMessageCount: number): number {
  if (historyMessageCount === 0) return -1;
  const stepSize = CACHE_REFRESH_EVERY * 2;
  const anchor = Math.floor((historyMessageCount - 1) / stepSize) * stepSize;
  // historyMessageCount === 1 → anchor = 0 → breakpoint on the first msg.
  // historyMessageCount in [stepSize, stepSize*2-1] → anchor = stepSize-1 → on stepSize-th.
  return Math.max(0, anchor + stepSize - 1);
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

function buildSkillsSection(skills: BuildMessagesInput['skills']): string {
  if (!skills.length) return '';
  return skills
    .map(
      (s) =>
        `## Skill: ${s.name}\n**When to use**: ${s.description}\n\n${s.body}`,
    )
    .join('\n\n');
}

// Wraps a string content into the Anthropic content-block array form so we
// can attach `cache_control` to it. OpenRouter passes this through to
// Anthropic models; for non-Anthropic providers it's a no-op (they ignore
// the block-array form for plain text).
function withCacheControl(text: string): { type: 'text'; text: string; cache_control: { type: 'ephemeral' } }[] {
  return [{ type: 'text', text, cache_control: { type: 'ephemeral' } }];
}

export function buildMessages(input: BuildMessagesInput): ChatCompletionMessageParam[] {
  const {
    bot,
    botMemory,
    reflections,
    skills,
    recentContext,
    newMessage,
    nowIso = new Date().toISOString(),
  } = input;

  const platform = getPrompt('system');
  const selfSection = buildSelfSection(botMemory, reflections);
  const skillsSection = buildSkillsSection(skills);
  const modeInstr = bot.output_mode === 'bubble' ? BUBBLE_INSTRUCTIONS : SINGLE_INSTRUCTIONS;
  const systemContent = [platform, selfSection, skillsSection, modeInstr]
    .filter(Boolean)
    .join('\n\n');

  // System message: always cached. Stable across turns until prompts change.
  const messages: ChatCompletionMessageParam[] = [
    { role: 'system', content: withCacheControl(systemContent) as unknown as string },
  ];

  // Build LLM-role history first so we know its length for breakpoint calc.
  const historyMsgs: Array<{ role: 'user' | 'assistant'; content: string }> = [];
  for (const m of recentContext) {
    const llmRole = toLlmRole(m.role);
    if (!llmRole) continue;
    const text = m.content ?? '';
    if (!text) continue;
    historyMsgs.push({ role: llmRole, content: `[${m.created_at}] ${text}` });
  }

  // Cache breakpoint on the chosen history index. Strategy: every 4 rounds
  // (8 messages) the breakpoint slides forward. Between slides every turn
  // is a pure cache hit on the prefix (system + history-up-to-breakpoint).
  const idx = input.cacheBreakpointHistoryIndex ?? computeCacheBreakpoint(historyMsgs.length);
  for (let i = 0; i < historyMsgs.length; i++) {
    const m = historyMsgs[i];
    if (i === idx) {
      messages.push({ role: m.role, content: withCacheControl(m.content) as unknown as string });
    } else {
      messages.push(m);
    }
  }

  // Current user turn — outside the cache (always fresh).
  messages.push({ role: 'user', content: `[${nowIso}] ${newMessage}` });

  return messages;
}
