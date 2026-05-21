import type {
  ChatCompletionMessageParam,
  ChatCompletionContentPart,
} from 'openai/resources/chat/completions';
import { classifyAttachment } from '../lib/attachments';
import { loadPrompt } from '../i18n/prompts';
import { DEFAULT_LOCALE, type Locale } from '../i18n/types';
import type { SupabaseClient } from '../lib/supabase';
import type { Memory } from '../lib/memory';

export interface BuildMessagesInput {
  bot: {
    id: string;
    output_mode: 'single' | 'bubble';
    // The bot's display name (bots.display_name) — the name the user gave
    // it and what everyone calls it by. Injected as a system section so
    // the bot knows its own name. May be empty on unnamed/legacy rows.
    display_name?: string | null;
    // IANA timezone the bot considers itself in (bots.tz). Public bots
    // only; private bots leave it null and fall back to the listener's
    // clientTz. When set: (1) appears in the system prompt as "你所在的
    // 时区是 X" for self-awareness; (2) used as the time-hint tz when no
    // clientTz is available (group dispatch).
    tz?: string | null;
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
  // Per-conversation markdown the bot keeps for itself — rough timeline of
  // what got talked about plus quotes worth remembering. Index to the
  // search_chat_history tool, not a transcript. Null until first refresh.
  chatMemo: string | null;
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
  /// Image content parts to attach to the *current* user turn — only set
  /// when the main model has vision. Each part is an OpenAI-style
  /// {type:'image_url', image_url:{url:'data:...'}} block. When present,
  /// the user message goes out as a content array (text + images) so the
  /// model reads the image directly. When absent or empty, the model only
  /// sees the text turn — but the inventory section below carries the
  /// summary as a fallback signal.
  currentImageParts?: ChatCompletionContentPart[];
  /// File content parts ({type:'file'}) for the *current* user turn —
  /// PDFs, which the provider parses natively. Appended to the user
  /// message content array alongside currentImageParts. Non-PDF files
  /// are never sent inline; they ride the attachment inventory only.
  currentFileParts?: ChatCompletionContentPart[];
  /// One row per attachment visible in this conv's recent history
  /// (typically last ~30). Images render as "[图 ID:...] 摘要..." lines;
  /// non-image files render as "[文件 ID:...] 文件名" lines in a separate
  /// block. Built by the caller and rendered as system context blocks.
  /// Empty array / undefined → sections omitted.
  attachmentInventory?: Array<{
    id: string;
    summary: string | null;
    tags: string[];
    /// 'pending' / 'failed' get a small note in the rendered line so the
    /// model knows the summary isn't available yet (and shouldn't
    /// hallucinate). 'done' is the normal case. Files are 'skipped'.
    status: 'pending' | 'done' | 'failed' | 'skipped' | string;
    /// Whether the row belongs to *this* turn's user message — flagged
    /// in rendering so the model can correlate "the user just sent this
    /// image" without us putting the summary inside the user turn.
    isCurrentTurn?: boolean;
    /// MIME + original filename. mime drives image-vs-file classification
    /// in the inventory; filename labels file rows. Absent (null) for
    /// legacy image rows — treated as an image.
    mime?: string | null;
    filename?: string | null;
  }>;
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
async function buildSelfSection(
  supa: SupabaseClient,
  botMemory: BuildMessagesInput['botMemory'],
  locale: Locale,
): Promise<string> {
  const hasMemory = !!botMemory && botMemory.representation.trim().length > 0;
  if (!hasMemory) return loadPrompt(supa, 'identity-quest', locale);
  return `## How I observe myself (passive)\n${botMemory!.representation.trim()}`;
}

// The bot's own name. A plain fact, not a persona — placed near the top
// so the bot can answer "你叫什么名字" without inventing one. Empty/legacy
// rows just drop the section.
function buildIdentitySection(displayName: string | null | undefined): string {
  const name = displayName?.trim();
  if (!name) return '';
  return `## 你的名字\n你叫「${name}」。这是用户给你起的名字，别人也用这个名字称呼你。`;
}

// Bot's own timezone — only meaningful for public bots (private bots
// always 1:1 with their creator and the per-turn time hint already
// renders in the user's clientTz). When set, the bot can reason about
// "tomorrow" / "this morning" relative to its own clock, and in group
// chats this same tz drives the per-message time hints.
function buildBotTzSection(tz: string | null | undefined): string {
  const t = tz?.trim();
  if (!t) return '';
  return `## 你所在的时区\n你所在的时区是 ${t}（IANA 名）。当对方说「明天 / 今早 / 周末」这类相对时间时，按这个时区理解。`;
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

function buildChatMemoSection(memo: string | null): string {
  if (!memo || !memo.trim()) return '';
  return [
    '## 我跟 ta 的对话备忘 (chat-memo)',
    '（这份备忘是你自己写的、只有自己看得到。记的是这个对话里聊过什么大致时间段、哪些原文印象深刻——给「未来的你」做索引。）',
    '需要回看原文时调 `search_chat_history` 工具按关键词或时间段查（只能搜当前这个对话）。',
    '',
    memo.trim(),
  ].join('\n');
}

// Render the attachment inventory as system context blocks. Images and
// non-image files are listed separately:
//   - "## 历史图片附件" — "[图 ID:xxxxxxxx] 摘要... 标签: a, b" rows
//   - "## 文件附件"     — "[文件 ID:xxxxxxxx] 文件名 (mime)" rows
// The bare 8-char prefix is what the model passes to read_attachment
// when it needs more detail (the tool resolves a full UUID or any
// unique prefix).
function buildAttachmentInventorySection(
  inv: BuildMessagesInput['attachmentInventory'],
): string {
  if (!inv || inv.length === 0) return '';
  // A row with no mime is a legacy image (all attachments were images
  // before arbitrary-file support landed).
  const isImageRow = (a: NonNullable<typeof inv>[number]) =>
    !a.mime || classifyAttachment(a.mime) === 'image';
  const imageRows = inv.filter(isImageRow);
  const fileRows = inv.filter((a) => !isImageRow(a));

  const sections: string[] = [];

  if (imageRows.length > 0) {
    const lines = imageRows.map((a) => {
      const idShort = a.id.slice(0, 8);
      const idLabel = a.isCurrentTurn ? `${idShort}（本轮）` : idShort;
      if (a.status !== 'done' || !a.summary) {
        const why =
          a.status === 'pending'
            ? '摘要生成中'
            : a.status === 'failed'
              ? '摘要失败'
              : a.status === 'skipped'
                ? '摘要已跳过'
                : `摘要状态:${a.status}`;
        return `- [图 ID:${idLabel}] (${why}，无文字描述。需要的话可以调 read_attachment 直接看图。)`;
      }
      const tagPart = a.tags.length > 0 ? `  标签: ${a.tags.join(', ')}` : '';
      return `- [图 ID:${idLabel}] ${a.summary}${tagPart}`;
    });
    sections.push(
      [
        '## 历史图片附件',
        '这个会话里出现过下列图片，已由识图模型预先生成摘要。如果摘要不够用、需要看图本身的细节，调用 `read_attachment` 工具（参数 `attachment_id` 填上面 [图 ID:xxx] 的 8 位前缀或完整 UUID，`question` 提具体问题）。',
        ...lines,
      ].join('\n'),
    );
  }

  if (fileRows.length > 0) {
    const lines = fileRows.map((a) => {
      const idShort = a.id.slice(0, 8);
      const idLabel = a.isCurrentTurn ? `${idShort}（本轮）` : idShort;
      const name = a.filename || '未命名文件';
      const mime = a.mime || '未知类型';
      const isPdf = !!a.mime && classifyAttachment(a.mime) === 'pdf';
      const hint =
        a.isCurrentTurn && isPdf
          ? '，已作为可解析文件直接附在本轮消息里'
          : '';
      return `- [文件 ID:${idLabel}] ${name} (${mime}${hint})`;
    });
    sections.push(
      [
        '## 文件附件',
        '这个会话里出现过下列文件。要读取某个文件的内容，调用 `read_attachment` 工具（参数 `attachment_id` 填上面 [文件 ID:xxx] 的 8 位前缀或完整 UUID，`question` 写你想从文件里得到什么）。文本类文件会原样返回内容，PDF 会按问题解析；标注「已直接附在本轮消息里」的 PDF 你已经能直接看到，不必再调工具。',
        ...lines,
      ].join('\n'),
    );
  }

  return sections.join('\n\n');
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
  return `${parts.y}年${parts.mo}月${parts.d}日 ${pad(parts.h)}:${pad(parts.mi)}:${pad(parts.s)}`;
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

// System-prompt-only assembly. Returns the joined system text without any
// of the user/assistant history wrapper messages — useful for callers that
// only need the system block (e.g. realtime voice SDKs whose `instructions`
// field IS the system prompt).
export type BuildSystemPromptInput = Pick<
  BuildMessagesInput,
  | 'bot'
  | 'botMemory'
  | 'skills'
  | 'botNote'
  | 'chatMemo'
  | 'lookbacks'
  | 'attachmentInventory'
>;

// Which surface the prompt is for. 'text' is the default IM chat; 'voice' is a
// realtime call, which swaps the platform core for the spoken-style `voice`
// prompt and drops the text-only bubble/single output-mode instructions.
export type PromptSurface = 'text' | 'voice';

export async function buildSystemPrompt(
  supa: SupabaseClient,
  input: BuildSystemPromptInput,
  locale: Locale = DEFAULT_LOCALE,
  surface: PromptSurface = 'text',
): Promise<string> {
  const [platform, selfSection] = await Promise.all([
    loadPrompt(supa, surface === 'voice' ? 'voice' : 'system', locale),
    buildSelfSection(supa, input.botMemory, locale),
  ]);
  const identitySection = buildIdentitySection(input.bot.display_name);
  const botTzSection = buildBotTzSection(input.bot.tz);
  const skillsSection = buildSkillsSection(input.skills);
  const botNoteSection = buildBotNoteSection(input.botNote);
  const chatMemoSection = buildChatMemoSection(input.chatMemo);
  const lookbackSection = buildLookbackSection(input.lookbacks);
  const attachmentSection = buildAttachmentInventorySection(input.attachmentInventory);
  // Bubble/single segmentation is a text-chat concept; voice has no message
  // splitting, so the mode instruction drops out (filtered as '' below).
  const modeInstr =
    surface === 'voice'
      ? ''
      : input.bot.output_mode === 'bubble'
        ? BUBBLE_INSTRUCTIONS
        : SINGLE_INSTRUCTIONS;
  // attachmentSection sits between lookbacks and modeInstr — out of the
  // cached prefix because the inventory mutates with every new image,
  // before the always-mutating mode/recent-turn segment. chat-memo sits
  // right after bot-note since both are bot-private long-term context.
  // botTzSection rides next to identity — both are stable bot-facts.
  return [
    platform, identitySection, botTzSection, selfSection, skillsSection,
    botNoteSection, chatMemoSection, lookbackSection, attachmentSection, modeInstr,
  ].filter(Boolean).join('\n\n');
}

export async function buildMessages(
  supa: SupabaseClient,
  input: BuildMessagesInput,
  locale: Locale = DEFAULT_LOCALE,
): Promise<ChatCompletionMessageParam[]> {
  const {
    recentContext,
    newMessage,
    clientTz,
    nowIso = new Date().toISOString(),
  } = input;
  // Time-hint tz resolution: 1:1 has clientTz (listener's device tz);
  // group dispatch has no clientTz but the bot has its own tz on
  // bots.tz. Fall back in that order; UTC is the last resort.
  const timeHintTz = clientTz ?? input.bot.tz ?? undefined;

  const systemContent = await buildSystemPrompt(supa, input, locale);

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
      content: llmRole === 'user' ? withTimeHint(text, m.created_at, timeHintTz) : text,
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

  // Current user turn — outside the cache (always fresh). When the
  // caller passed image parts (main model has vision) and/or file parts
  // (PDFs), send a content array so the model reads them directly.
  // Otherwise plain text — the attachment-inventory section above
  // carries the summary / file listing.
  const userText = withTimeHint(newMessage, nowIso, timeHintTz);
  const currentParts: ChatCompletionContentPart[] = [
    ...(input.currentImageParts ?? []),
    ...(input.currentFileParts ?? []),
  ];
  if (currentParts.length > 0) {
    messages.push({
      role: 'user',
      content: [{ type: 'text', text: userText }, ...currentParts],
    });
  } else {
    messages.push({ role: 'user', content: userText });
  }

  return messages;
}
