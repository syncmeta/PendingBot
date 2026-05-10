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
  // Skills the user has subscribed (globally and/or for this conv). Each
  // contributes a `## Skill: ...` block to system content.
  skills: Array<{ name: string; description: string; body: string }>;
  // Bot's private "manual on relating to this user" — written by the bot
  // itself over time, never shown to the user. Null when the bot hasn't
  // written one yet (cold start).
  botNote: string | null;
  // Active lookback notes from the lookback runner — fact-check / clarify
  // jots the bot wrote about prior turns. Each is presented as a context
  // block; the bot may emit [DROP_LOOKBACK] in its reply to retire them.
  lookbacks?: Array<{ id: string; body_md: string }>;
  // Recent history from the client's local cache (POST body). Already
  // ordered ascending by created_at on the client side.
  recentContext: Array<{
    role: 'user' | 'bot' | 'human' | 'log';
    content?: string | null;
    created_at: string; // ISO 8601 with timezone
  }>;
  newMessage: string;
  // IANA timezone from the client (e.g. "Asia/Shanghai"). Used to format
  // the *current* user turn's timestamp (server only knows UTC for "now").
  // Historical messages carry their own offset in `created_at`, so we
  // format those from the offset embedded in each ISO string and ignore
  // clientTz for them — keeps display correct even if the user travelled.
  clientTz?: string;
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
  return null;
}

// Self section comes from the bot's passive Honcho representation. On cold
// start (no memory yet) we hand the bot the identity-quest meta-prompt — a
// motive, not a persona.
function buildSelfSection(
  botMemory: BuildMessagesInput['botMemory'],
): string {
  const hasMemory = !!botMemory && botMemory.representation.trim().length > 0;
  if (!hasMemory) return getPrompt('identity-quest');
  return `## How I observe myself (passive)\n${botMemory!.representation.trim()}`;
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

function buildBotNoteSection(note: string | null): string {
  if (!note || !note.trim()) return '';
  return [
    '## 我对这个用户的私人笔记',
    '（这份笔记是你过去自己整理的，对方看不到——交往时参考着用。）',
    '',
    note.trim(),
  ].join('\n');
}

function buildLookbackSection(lookbacks: BuildMessagesInput['lookbacks']): string {
  if (!lookbacks || lookbacks.length === 0) return '';
  const items = lookbacks.map((l) => `- ${l.body_md.trim()}`).join('\n');
  return [
    '## 上一轮我自己的查证笔记（仅你可见，对方看不到）',
    items,
    '',
    '处理规则：',
    '- 笔记里的内容如果跟接下来的话题有关，自然地融入回复（比如更正自己之前的说法、提示对方一个事实）。',
    '- 如果你回复完之后觉得这条笔记**已经用完了 / 不再需要带在身上了**，在你给对方的回复末尾另起一行写 `[DROP_LOOKBACK]`（这一行系统会替你抹掉，对方看不到）。',
    '- 如果还想留着以备后续用，正常回复即可，不写 [DROP_LOOKBACK]。',
  ].join('\n');
}

// Format a timestamp as a natural Chinese phrase the model is unlikely to
// mimic verbatim. We wrap it as an explicit "system hint" so even if the
// model does echo it back, the user-facing layer can strip it.
//
// `iso` carries its own offset (e.g. "2026-05-08T11:23:45+08:00"); we honor
// that offset directly. For server-generated `now` (UTC `Z`), pass the
// client's IANA tz via `tzFallback` so we can render in their local clock.
function formatTimeHint(iso: string, tzFallback?: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';

  // If the ISO string explicitly carries an offset (anything other than `Z`
  // -- including the `Z` case, which we treat as "no client offset known"),
  // extract minutes-offset from the suffix.
  const offsetMatch = /([+-])(\d{2}):?(\d{2})$/.exec(iso);
  let parts: { y: number; mo: number; d: number; h: number; mi: number; s: number };

  if (offsetMatch) {
    const sign = offsetMatch[1] === '-' ? -1 : 1;
    const offMin = sign * (parseInt(offsetMatch[2], 10) * 60 + parseInt(offsetMatch[3], 10));
    const shifted = new Date(d.getTime() + offMin * 60_000);
    parts = {
      y: shifted.getUTCFullYear(),
      mo: shifted.getUTCMonth() + 1,
      d: shifted.getUTCDate(),
      h: shifted.getUTCHours(),
      mi: shifted.getUTCMinutes(),
      s: shifted.getUTCSeconds(),
    };
  } else if (tzFallback) {
    // ISO is UTC `Z` but client gave us an IANA zone — render via Intl.
    try {
      const fmt = new Intl.DateTimeFormat('en-CA', {
        timeZone: tzFallback,
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit',
        hour12: false,
      });
      const map: Record<string, string> = {};
      for (const p of fmt.formatToParts(d)) {
        if (p.type !== 'literal') map[p.type] = p.value;
      }
      parts = {
        y: parseInt(map.year, 10),
        mo: parseInt(map.month, 10),
        d: parseInt(map.day, 10),
        h: parseInt(map.hour === '24' ? '0' : map.hour, 10),
        mi: parseInt(map.minute, 10),
        s: parseInt(map.second, 10),
      };
    } catch {
      parts = {
        y: d.getUTCFullYear(),
        mo: d.getUTCMonth() + 1,
        d: d.getUTCDate(),
        h: d.getUTCHours(),
        mi: d.getUTCMinutes(),
        s: d.getUTCSeconds(),
      };
    }
  } else {
    parts = {
      y: d.getUTCFullYear(),
      mo: d.getUTCMonth() + 1,
      d: d.getUTCDate(),
      h: d.getUTCHours(),
      mi: d.getUTCMinutes(),
      s: d.getUTCSeconds(),
    };
  }

  const pad = (n: number) => String(n).padStart(2, '0');
  return `${parts.mo}月${parts.d}日 ${pad(parts.h)}:${pad(parts.mi)}:${pad(parts.s)}`;
}

function withTimeHint(text: string, iso: string, tzFallback?: string): string {
  const t = formatTimeHint(iso, tzFallback);
  if (!t) return text;
  return `${text}\n（系统提示：此消息发送于 ${t}。此提示用户不可见，你也**不要**模仿此格式输出）`;
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
    skills,
    recentContext,
    newMessage,
    clientTz,
    nowIso = new Date().toISOString(),
  } = input;

  const platform = getPrompt('system');
  const selfSection = buildSelfSection(botMemory);
  const skillsSection = buildSkillsSection(skills);
  const botNoteSection = buildBotNoteSection(input.botNote);
  const lookbackSection = buildLookbackSection(input.lookbacks);
  const modeInstr = bot.output_mode === 'bubble' ? BUBBLE_INSTRUCTIONS : SINGLE_INSTRUCTIONS;
  const systemContent = [
    platform, selfSection, skillsSection,
    botNoteSection, lookbackSection, modeInstr,
  ].filter(Boolean).join('\n\n');

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
    historyMsgs.push({
      role: llmRole,
      content: llmRole === 'user' ? withTimeHint(text, m.created_at, clientTz) : text,
    });
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
  messages.push({ role: 'user', content: withTimeHint(newMessage, nowIso, clientTz) });

  return messages;
}
