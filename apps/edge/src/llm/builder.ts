import type { ChatCompletionMessageParam } from 'openai/resources/chat/completions';
import { getPrompt } from './prompt-loader';

// Inputs the route handler hands us. Keep this surface minimal — Honcho
// memory, skills, and bot_reflections land in B7 and slot into the same
// builder, expanding the system message.
export interface BuildMessagesInput {
  bot: {
    id: string;
    output_mode: 'single' | 'bubble';
  };
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

export function buildMessages(input: BuildMessagesInput): ChatCompletionMessageParam[] {
  const { bot, recentContext, newMessage, nowIso = new Date().toISOString() } = input;

  // System content: platform prompt + (B7: self section) + output mode.
  // We keep the assembly explicit so future additions slot at named seams.
  const platform = getPrompt('system');
  const modeInstr = bot.output_mode === 'bubble' ? BUBBLE_INSTRUCTIONS : SINGLE_INSTRUCTIONS;
  const systemContent = [platform, modeInstr].join('\n\n');

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
