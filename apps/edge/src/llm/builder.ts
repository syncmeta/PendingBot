import type {
  ChatCompletionMessageParam,
  ChatCompletionContentPart,
} from 'openai/resources/chat/completions';
import { classifyAttachment } from '../lib/attachments';
import { loadPrompt } from '../i18n/prompts';
import { DEFAULT_LOCALE, type Locale } from '../i18n/types';
import type { Env } from '../types';
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
  // ① Bot's own GLOBAL self-representation (Honcho passive observation)
  // cached in KV. Null on cold start — we then fall back to the
  // identity-quest meta-prompt.
  botMemory: Memory | null;
  // ② Bot's LOCAL model of this user ("how I read this person"). Pair-scoped
  // theory-of-mind. Only set for regular 1v1 turns; omitted in group / self.
  // Null until first refresh → section dropped.
  botViewOfUser?: Memory | null;
  // ④ User's LOCAL model of this bot ("how this person seems to see me").
  // Pair-scoped — lets the bot see itself through the user's eyes, which can
  // diverge from its own self-image (①). Same gating/cold-start as ②.
  userViewOfBot?: Memory | null;
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
  /// block. Built by the caller; rendered into the per-turn volatile
  /// context that rides the current user turn (out of the cached prefix —
  /// the inventory mutates with every new image). Empty/undefined → omitted.
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
  // Pending answers from prior ask_friend calls that resolved while the
  // caller_conv was "active" — submit_inquiry_answer parked them here
  // instead of inserting a spontaneous message. The bot should weave
  // them into its reply this turn. Marked answered_delivered the moment
  // we read them, so they only surface once (lost if the turn errors,
  // by design — beats double-delivering).
  pendingInquiryAnswers?: Array<{
    inquiry_id: string;
    target_display_name: string;
    question: string;
    answer: string;
  }>;
  // Open inquiries this bot raised that now ride this conversation as
  // the relay. Surfaces the inquiry_id so the bot can find it when it
  // decides to call submit_inquiry_answer — without this, ask_friend's
  // tool-result envelope only lives in the current turn's tool-call
  // memory and is gone by the next turn.
  openRelayInquiries?: Array<{
    inquiry_id: string;
    question: string;
  }>;
  // Bot's own social graph — small per-turn snapshot used by the social
  // section. Counts + top-N display names for human friends and groups.
  // Refreshed each turn (cheap) and rendered into the *volatile* per-turn
  // context, so adding/removing a friend doesn't bust the persona cache.
  // The detailed rules (visibility, ask_friend semantics, etc.) live in
  // the static bot-social-graph skill body in the stable prefix.
  socialGraph?: {
    friendsCount: number;
    recentFriends: Array<{ display_name: string }>;
    groupsCount: number;
    recentGroups: Array<{ title: string | null }>;
    /// True iff the bot is public_invite — gates whether the social
    /// section mentions `ask_friend` (which only public bots have).
    isPublic: boolean;
  };
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
  env: Env,
  botMemory: BuildMessagesInput['botMemory'],
  locale: Locale,
): Promise<string> {
  const hasMemory = !!botMemory && botMemory.representation.trim().length > 0;
  if (!hasMemory) return loadPrompt(env, 'identity-quest', locale);
  return `## How I observe myself (passive)\n${botMemory!.representation.trim()}`;
}

// ② Bot's standing read on the person it's talking to. Honcho's local
// representation of the user from the bot's perspective — pooled across every
// session the pair shares. Passive context, not a directive.
function buildUserModelSection(botViewOfUser: Memory | null | undefined): string {
  const rep = botViewOfUser?.representation.trim();
  if (!rep) return '';
  return `## How I read this person (passive · 我对ta的认知)\n${rep}`;
}

// ④ How the user seems to model the bot. Honcho's representation of the bot
// from the *user's* perspective — "myself through their eyes". May diverge
// from the bot's own self-image above; that gap is the point.
function buildPerceivedSelfSection(userViewOfBot: Memory | null | undefined): string {
  const rep = userViewOfBot?.representation.trim();
  if (!rep) return '';
  return `## How this person seems to see me (passive · ta 眼中的我)\n${rep}`;
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

// Per-turn snapshot of the bot's social graph — counts + a handful of
// recent friends/groups by name. Lives in the volatile context so adding
// or removing a friend doesn't bust the cached persona. The static rules
// (visibility, ask_friend semantics, etc.) sit above in the persona via
// buildSocialGraphSkillSection — this section just gives the bot today's
// numbers and a few labels it can drop into conversation if asked.
function buildSocialGraphStatsSection(
  sg: BuildMessagesInput['socialGraph'],
): string {
  if (!sg) return '';
  const friendLabels = sg.recentFriends
    .map((f) => f.display_name.trim())
    .filter((s) => s.length > 0)
    .slice(0, 5);
  const groupLabels = sg.recentGroups
    .map((g) => (g.title ?? '').trim())
    .filter((s) => s.length > 0)
    .slice(0, 5);
  const lines: string[] = ['## 我自己的社交圈（本回合快照）'];
  if (sg.friendsCount === 0) {
    lines.push('- 目前还没人加我为好友。');
  } else {
    const recent = friendLabels.length > 0
      ? `，最近的几位：${friendLabels.join('、')}`
      : '';
    lines.push(`- 我有 ${sg.friendsCount} 个人类好友${recent}。`);
  }
  if (sg.groupsCount === 0) {
    lines.push('- 我目前不在任何群里。');
  } else {
    const recent = groupLabels.length > 0
      ? `，最近活跃的几个：${groupLabels.join('、')}`
      : '';
    lines.push(`- 我在 ${sg.groupsCount} 个群里${recent}。`);
  }
  if (sg.isPublic) {
    lines.push('- 我是公有机器人，可以用 `ask_friend` 主动问其他好友（详见 skill `bot-social-graph`）。');
  } else {
    lines.push('- 我是私有机器人，没有 `ask_friend` —— 这套工具只对公有机器人开放。');
  }
  return lines.join('\n');
}


// Answers from prior ask_friend calls that finished while THIS conv
// (the caller side) was active. submit_inquiry_answer parked them on
// the inquiry row; bot-reply read + cleared them. The bot should weave
// the contents into its current reply rather than dropping them as a
// separate bubble — that's the whole point of the active-injection
// path. Lives in volatile context (per-turn, never cached).
function buildPendingInquiryAnswersSection(
  pending: BuildMessagesInput['pendingInquiryAnswers'],
): string {
  if (!pending || pending.length === 0) return '';
  const items = pending.map((p) => {
    const target = p.target_display_name || '某位好友';
    return `- 你之前问 ${target}「${p.question}」—— 对方那边的对话已经收尾，转述给你的答案是：\n  ${p.answer}`;
  });
  return [
    '## 刚回来的好友问询',
    '（这些是你之前用 ask_friend 问出去、submit_inquiry_answer 已经收尾的答案。caller 这边正活跃，所以没有作为独立消息发出，需要你在本回合的回复里自然融入。不必逐字转述，按对话氛围吸收即可。）',
    '',
    ...items,
  ].join('\n');
}

// Reminder section when the current conv IS the relay side of one or
// more open inquiries (i.e. you, the bot, are sitting in your 1v1 with
// a human friend you ask_friend'd earlier). Just lists inquiry_id +
// question so the bot has the id at hand when it wants to call
// submit_inquiry_answer. Without this, the id is lost across turns —
// tool-call envelopes don't carry into the next round's history.
function buildOpenRelayInquiriesSection(
  open: BuildMessagesInput['openRelayInquiries'],
): string {
  if (!open || open.length === 0) return '';
  const items = open.map(
    (q) => `- inquiry_id=\`${q.inquiry_id}\` — 原始提问：「${q.question}」`,
  );
  return [
    '## 这个对话上挂着等回收尾的 inquiry',
    '（你之前在另一个会话里发起的 ask_friend，目标就是当前这位好友。等你和对方对话清楚、有答案可以转述回去时，调 `submit_inquiry_answer(inquiry_id, answer)` 收尾。）',
    '',
    ...items,
  ].join('\n');
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
  | 'botViewOfUser'
  | 'userViewOfBot'
  | 'skills'
  | 'botNote'
  | 'chatMemo'
  | 'lookbacks'
  | 'attachmentInventory'
  | 'socialGraph'
  | 'pendingInquiryAnswers'
  | 'openRelayInquiries'
>;

// Which surface the prompt is for. Each maps to its own platform prompt:
//   'text'        → `system`        (IM chat, the default)
//   'voice'       → `voice`         (1:1 realtime call, spoken style)
//   'group-voice' → `group-voice`   (multi-party voice room, turn-taking)
// Both voice surfaces drop the text-only bubble/single output-mode block.
export type PromptSurface = 'text' | 'voice' | 'group-voice';

const PLATFORM_PROMPT_BY_SURFACE = {
  'text': 'system',
  'voice': 'voice',
  'group-voice': 'group-voice',
} as const;

// Stable persona block — the cacheable prefix. Everything here is stable
// across turns until the persona itself changes (self/skills/notes update
// on an hours-scale, not per-turn), so it sits BEFORE the cache breakpoint.
// modeInstr rides here too: it's a fixed per-bot fact, not per-turn context.
async function buildStablePersona(
  env: Env,
  input: BuildSystemPromptInput,
  locale: Locale,
  surface: PromptSurface,
): Promise<string> {
  const [platform, selfSection, socialGraphSkillSection] = await Promise.all([
    loadPrompt(env, PLATFORM_PROMPT_BY_SURFACE[surface], locale),
    buildSelfSection(env, input.botMemory, locale),
    // bot-social-graph skill body — always-on, editable via Langfuse Prompt
    // Management. Loaded through the same prompt-loader cache as the platform
    // prompt, so per-isolate this is a Map lookup after the first turn.
    loadPrompt(env, 'bot-social-graph', locale),
  ]);
  const identitySection = buildIdentitySection(input.bot.display_name);
  const botTzSection = buildBotTzSection(input.bot.tz);
  // Theory-of-mind context (1v1 only; null/omitted elsewhere → '').
  const userModelSection = buildUserModelSection(input.botViewOfUser);       // ②
  const perceivedSelfSection = buildPerceivedSelfSection(input.userViewOfBot); // ④
  const skillsSection = buildSkillsSection(input.skills);
  const botNoteSection = buildBotNoteSection(input.botNote);
  const chatMemoSection = buildChatMemoSection(input.chatMemo);
  // Bubble/single segmentation is a text-chat concept; voice (1:1 or group)
  // has no message splitting, so the mode instruction drops out for any
  // non-text surface. The instruction bodies live in Langfuse
  // (output-mode-bubble / output-mode-single), loaded through the same
  // prompt-loader cache as the platform prompt above.
  const modeInstr =
    surface !== 'text'
      ? ''
      : await loadPrompt(
          env,
          input.bot.output_mode === 'bubble' ? 'output-mode-bubble' : 'output-mode-single',
          locale,
        );
  return [
    platform, identitySection, botTzSection, modeInstr,
    selfSection, userModelSection, perceivedSelfSection,
    socialGraphSkillSection,
    skillsSection, botNoteSection, chatMemoSection,
  ].filter(Boolean).join('\n\n');
}

// Per-turn volatile context — attachment inventory (mutates with every new
// image/file) + lookback notes (added/dropped almost every round). Kept OUT
// of the cached prefix: in buildMessages it rides on the current user turn
// (never cached anyway), so a change here never busts the persona/history
// cache. For voice it's just appended to the instructions string.
function buildVolatileContext(input: BuildSystemPromptInput): string {
  const attachmentSection = buildAttachmentInventorySection(input.attachmentInventory);
  const lookbackSection = buildLookbackSection(input.lookbacks);
  const socialStatsSection = buildSocialGraphStatsSection(input.socialGraph);
  const pendingAnswersSection = buildPendingInquiryAnswersSection(
    input.pendingInquiryAnswers,
  );
  const openRelaySection = buildOpenRelayInquiriesSection(input.openRelayInquiries);
  return [
    attachmentSection,
    lookbackSection,
    socialStatsSection,
    pendingAnswersSection,
    openRelaySection,
  ]
    .filter(Boolean)
    .join('\n\n');
}

export async function buildSystemPrompt(
  env: Env,
  input: BuildSystemPromptInput,
  locale: Locale = DEFAULT_LOCALE,
  surface: PromptSurface = 'text',
): Promise<string> {
  // Voice (and any caller that wants the whole prompt as one string) gets
  // stable persona + volatile context concatenated — there's no message
  // array to spread the cache breakpoint across, so the split is moot here.
  const [stable, volatile] = await Promise.all([
    buildStablePersona(env, input, locale, surface),
    Promise.resolve(buildVolatileContext(input)),
  ]);
  return [stable, volatile].filter(Boolean).join('\n\n');
}

export async function buildMessages(
  env: Env,
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

  // Stable persona → the cached system prefix. Volatile per-turn context
  // (attachment inventory + lookbacks) is built separately and ride the
  // current user turn below, so it never invalidates the persona/history
  // cache (Anthropic only caches all-or-nothing up to a breakpoint; OpenAI
  // caches the longest stable prefix — either way, volatile content in the
  // system block would near-zero the hit rate).
  const stablePersona = await buildStablePersona(env, input, locale, 'text');
  const volatileContext = buildVolatileContext(input);

  // System message: cached. Stable across turns until the persona changes.
  const messages: ChatCompletionMessageParam[] = [
    { role: 'system', content: withCacheControl(stablePersona) as unknown as string },
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

  // Current user turn — outside the cache (always fresh). The volatile
  // per-turn context (attachment inventory + lookback notes) is prepended
  // here as its own text block so it stays out of the cached prefix while
  // still sitting right next to the message it's context for. Image parts
  // (main model has vision) and file parts (PDFs) follow so the model reads
  // them directly.
  const userText = withTimeHint(newMessage, nowIso, timeHintTz);
  const attachmentParts: ChatCompletionContentPart[] = [
    ...(input.currentImageParts ?? []),
    ...(input.currentFileParts ?? []),
  ];
  if (volatileContext || attachmentParts.length > 0) {
    const textParts: ChatCompletionContentPart[] = [];
    if (volatileContext) textParts.push({ type: 'text', text: volatileContext });
    textParts.push({ type: 'text', text: userText });
    messages.push({ role: 'user', content: [...textParts, ...attachmentParts] });
  } else {
    messages.push({ role: 'user', content: userText });
  }

  return messages;
}
