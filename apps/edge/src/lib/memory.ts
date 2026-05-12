import type { Env } from '../types';
import { honchoClient, userPeerId, botPeerId, conversationSessionId } from './honcho';
import { serviceClient } from './supabase';
import {
  FallbackError,
  recordAudit,
  usageFromCompletion,
  withFallback,
} from '../llm/router';

// Long-term memory cache backed by CF Workers KV. Two key namespaces:
//   user:${userId}  — derived "what bots see in this user" (transparency UI only)
//   bot:${botId}    — bot self-representation (injected into bot's system prompt)
//
// Refresh is lazy: it only fires when the client's local context window has
// moved past the messages this memory snapshot covers. Plan/02 — "刷新机制
// (lazy)". The LLM hot path never blocks on Honcho.

export interface Memory {
  card: string[];
  representation: string;
  syncedAt: string;             // ISO 8601
  lastCoveredMessageId: string | null;
}

const USER_PREFIX = 'user:';
const BOT_PREFIX = 'bot:';

export async function getUserMemory(env: Env, userId: string): Promise<Memory | null> {
  return env.MEMORY.get<Memory>(USER_PREFIX + userId, 'json');
}

export async function getBotMemory(env: Env, botId: string): Promise<Memory | null> {
  return env.MEMORY.get<Memory>(BOT_PREFIX + botId, 'json');
}

export async function putUserMemory(env: Env, userId: string, memory: Memory): Promise<void> {
  await env.MEMORY.put(USER_PREFIX + userId, JSON.stringify(memory));
}

export async function putBotMemory(env: Env, botId: string, memory: Memory): Promise<void> {
  await env.MEMORY.put(BOT_PREFIX + botId, JSON.stringify(memory));
}

export interface MaybeRefreshInput {
  env: Env;
  userId: string;
  botId: string;
  conversationId: string;
  /// The oldest message id still inside the client's local context window.
  /// If this is *newer* than `memory.lastCoveredMessageId`, the client is
  /// about to drop messages between the two boundaries — we ingest them
  /// into Honcho so they don't go unobserved.
  oldestContextMessageId: string;
}

/// Decide whether to refresh, then do it. Safe to call from `ctx.waitUntil`.
/// All errors are swallowed — failure leaves the previous KV intact and the
/// next call will retry the same range.
export async function maybeRefreshMemory(input: MaybeRefreshInput): Promise<void> {
  const { env, userId, botId, conversationId, oldestContextMessageId } = input;
  try {
    const [userMemory, botMemory] = await Promise.all([
      getUserMemory(env, userId),
      getBotMemory(env, botId),
    ]);

    // Pick the older coverage point — both peers should ingest the same range
    // (they observe the same session). On cold start either may be null;
    // in that case we ingest "everything up to oldestContextMessageId".
    const userCovered = userMemory?.lastCoveredMessageId ?? null;
    const botCovered = botMemory?.lastCoveredMessageId ?? null;
    const sinceForUser = needsCatchUp(userCovered, oldestContextMessageId);
    const sinceForBot = needsCatchUp(botCovered, oldestContextMessageId);
    if (!sinceForUser && !sinceForBot) return;

    // Pull the message range to ingest. UUIDv7 is time-ordered, so a simple
    // `id < uptoId` range scan picks up everything with smaller timestamps;
    // we then filter to messages newer than each peer's last-covered point.
    const supa = serviceClient(env);
    const { data: msgs } = await supa
      .from('messages')
      .select('id, role, content, sender_bot_id, user_id, created_at')
      .eq('conversation_id', conversationId)
      .lt('id', oldestContextMessageId)
      .neq('role', 'log')
      .neq('status', 'deleted')  // recall: model must forget recalled messages
      .order('id', { ascending: true });
    if (!msgs?.length) return;

    const honcho = honchoClient(env);
    const session = await honcho.session(conversationSessionId(conversationId));

    // Push into Honcho, attributed to the right peer per row.
    const additions = msgs
      .filter((m) => m.content && (m.content as string).trim())
      .map((m) => {
        const peerId =
          m.role === 'bot'
            ? botPeerId((m.sender_bot_id as string) ?? botId)
            : userPeerId((m.user_id as string) ?? userId);
        return { peerId, content: m.content as string };
      })
      .filter((a) => sinceForUser || !a.peerId.startsWith('user-'))
      .filter((a) => sinceForBot || !a.peerId.startsWith('bot-'));
    if (additions.length === 0) return;
    await session.addMessages(additions);

    // Pull fresh representations and update KV. Each peer is updated only
    // if it actually had catch-up to do, so we don't overwrite a fresher
    // snapshot taken by a parallel turn.
    if (sinceForUser) {
      try {
        const peer = await honcho.peer(userPeerId(userId));
        const ctx = await peer.context();
        await putUserMemory(env, userId, {
          card: ctx.peerCard ?? [],
          representation: ctx.representation ?? '',
          syncedAt: new Date().toISOString(),
          lastCoveredMessageId: oldestContextMessageId,
        });
      } catch (err) {
        console.warn('[memory] user refresh failed', err);
      }
    }
    if (sinceForBot) {
      try {
        const peer = await honcho.peer(botPeerId(botId));
        const ctx = await peer.context();
        await putBotMemory(env, botId, {
          card: ctx.peerCard ?? [],
          representation: ctx.representation ?? '',
          syncedAt: new Date().toISOString(),
          lastCoveredMessageId: oldestContextMessageId,
        });
      } catch (err) {
        console.warn('[memory] bot refresh failed', err);
      }
    }

    // Piggyback bot's private "manual on this user" update on the same
    // trigger — same cadence as Honcho refresh, much cheaper than per-turn
    // and lazy enough that the LLM call doesn't pile up. chat-memo runs
    // in parallel; one is a (bot, user) cross-conv operating manual, the
    // other a per-conv log of "what we talked about / quotes I want to
    // keep" plus search-tool index — they serve different prompts.
    await Promise.all([
      refreshBotNote({ env, botId, userId, conversationId }),
      refreshChatMemo({ env, botId, conversationId }),
    ]);
  } catch (err) {
    console.warn('[memory] maybeRefresh failed', err);
  }
}

interface RefreshBotNoteInput {
  env: Env;
  botId: string;
  userId: string;
  conversationId: string;
}

/// Ask the bot to look at the recent transcript and the existing note,
/// then write the next iteration. Stored in `skills` (bot_id + user_id
/// set, owner_id null) so it lives under the same RLS-hidden umbrella
/// as bot-authored skills generally.
async function refreshBotNote(input: RefreshBotNoteInput): Promise<void> {
  const { env, botId, userId, conversationId } = input;
  const startedAt = Date.now();
  try {
    const supa = serviceClient(env);
    const { data: existing } = await supa
      .from('skills')
      .select('id, body_md')
      .eq('bot_id', botId)
      .eq('user_id', userId)
      .maybeSingle();

    // Pull last 30 non-log messages between this user and this bot for
    // the reflection prompt. Use the per-user_bot conv we're updating
    // from; broader cross-conv aggregation can come later.
    const { data: msgs } = await supa
      .from('messages')
      .select('role, content, created_at')
      .eq('conversation_id', conversationId)
      .neq('role', 'log')
      .neq('status', 'deleted')  // recall: reflection shouldn't include recalled rows
      .order('created_at', { ascending: false })
      .limit(30);
    const recent = (msgs ?? []).reverse();
    if (recent.length < 4) return; // not enough material to be worth a reflection

    // Pull the bot's model_id for the reflection LLM call.
    const { data: bot } = await supa
      .from('bots')
      .select('model_id, display_name')
      .eq('id', botId)
      .single();
    if (!bot?.model_id) return;

    const transcript = recent
      .map((m) => {
        const speaker = m.role === 'bot' ? '我' : '对方';
        return `${speaker}：${m.content ?? ''}`;
      })
      .join('\n');
    const currentNote = (existing?.body_md as string | undefined)?.trim() ?? '';

    const prompt = [
      `你（${bot.display_name}）正在更新一份只有自己能看到的私人笔记，记录跟这个用户交往的要领。`,
      '不是日记、不是总结，是「下次跟 ta 互动我自己要记得什么」。',
      '对方永远看不到这份笔记。语气放松，写给自己看。',
      '',
      currentNote
        ? `## 上一版笔记\n${currentNote}`
        : '## 上一版笔记\n（还没写过——这是第一版）',
      '',
      '## 最近对话',
      transcript,
      '',
      '## 任务',
      '基于最近对话和上一版，写出新一版笔记。控制在 600 字以内，要点优先，避免重复。',
      '直接输出 markdown 笔记正文，不要前言后语，不要"以下是更新版"这种元话语。',
    ].join('\n');

    const { result: completion, route, routeTrace } = await withFallback(
      supa,
      env,
      { modelSlug: bot.model_id as string, taskType: 'bot_note' },
      (r) =>
        r.client.chat.completions.create({
          model: r.modelToCall,
          messages: [{ role: 'user', content: prompt }],
        }),
    );
    const newBody = completion.choices[0]?.message?.content?.trim();
    await recordAudit(supa, route, {
      userId,
      conversationId,
      taskType: 'bot_note',
      startedAt,
      generationId: completion.id,
      status: 'success',
      routeTrace,
      metadata: { bot_id: botId, action: newBody ? 'update' : 'silent' },
      ...usageFromCompletion(completion.usage),
    });
    if (!newBody) return;

    if (existing?.id) {
      await supa
        .from('skills')
        .update({ body_md: newBody, updated_at: new Date().toISOString() })
        .eq('id', existing.id);
    } else {
      await supa.from('skills').insert({
        owner_id: null,
        bot_id: botId,
        user_id: userId,
        visibility: 'private',
        frontmatter: {
          name: `bot-note:${botId.slice(0, 8)}/${userId.slice(0, 8)}`,
          description: 'Bot private user-relating manual',
        },
        body_md: newBody,
      });
    }
  } catch (err) {
    console.warn('[memory] refreshBotNote failed', err);
    if (err instanceof FallbackError) {
      const supa = serviceClient(env);
      await recordAudit(supa, err.lastRoute, {
        userId,
        conversationId,
        taskType: 'bot_note',
        startedAt,
        status: 'error',
        errorClass:
          err.routeTrace[err.routeTrace.length - 1]?.error_class ?? 'unknown',
        routeTrace: err.routeTrace,
        metadata: { bot_id: botId, action: 'error' },
      });
    }
  }
}

interface RefreshChatMemoInput {
  env: Env;
  botId: string;
  conversationId: string;
}

/// Per-conv markdown the bot maintains for itself: a loose timeline of what
/// got talked about and which exact quotes (from either side) stuck with
/// it. Paired with the search_chat_history tool — the memo is the index,
/// the tool is the way back to original text. Stored on skills under the
/// new (bot_id+conversation_id) authorship branch so the row stays bot-
/// private regardless of conv type (1v1 / group / self).
///
/// Length is on the bot — prompt tells it to summarize / drop old material
/// when the memo grows past ~2 KiB. We don't enforce.
async function refreshChatMemo(input: RefreshChatMemoInput): Promise<void> {
  const { env, botId, conversationId } = input;
  const startedAt = Date.now();
  try {
    const supa = serviceClient(env);
    const { data: existing } = await supa
      .from('skills')
      .select('id, body_md' as never)
      .eq('bot_id', botId)
      .eq('conversation_id' as never, conversationId)
      .is('user_id', null)
      .maybeSingle<{ id: string; body_md: string }>();

    const { data: msgs } = await supa
      .from('messages')
      .select('role, content, created_at')
      .eq('conversation_id', conversationId)
      .neq('role', 'log')
      .neq('status', 'deleted')  // recall: skip recalled rows in memo build
      .order('created_at', { ascending: false })
      .limit(40);
    const recent = (msgs ?? []).reverse();
    if (recent.length < 4) return;

    const { data: bot } = await supa
      .from('bots')
      .select('model_id, display_name')
      .eq('id', botId)
      .single();
    if (!bot?.model_id) return;

    const transcript = recent
      .map((m) => {
        const speaker = m.role === 'bot' ? '我' : '对方';
        const ts = (m.created_at as string).slice(0, 16).replace('T', ' ');
        return `[${ts}] ${speaker}：${m.content ?? ''}`;
      })
      .join('\n');
    const currentMemo = (existing?.body_md ?? '').trim();

    const prompt = [
      `你（${bot.display_name}）在维护一份只有自己能看的对话备忘 (chat-memo)。`,
      '这份备忘是你给「未来的自己」准备的，对方永远看不到。它有两个用途：',
      '1) 记录时间段大概聊了什么——比如「~5月初：聊了关于 X 的几轮，对方提到 Y」；',
      '2) 摘录让你印象深刻的原文（不限是谁说的），让以后能定位到那一刻。每条原文带上大概的时间。',
      '',
      '写法没有强制 schema，按你舒服的方式组织（时间段分节最自然）。语气放松，给自己看。',
      '篇幅控制在 ~2KB 以内。如果上一版已经接近上限：',
      '- 把更早的时间段压缩成一行总结',
      '- 删掉重复的或不再有价值的原文摘录',
      '- 合并相邻的话题',
      '',
      '配套：你还有一个 `search_chat_history` 工具，可以用关键词或时间段回查这个对话的原文。',
      '所以备忘本身做「索引和点睛」就行，不必逐字——觉得重要时再调工具回查。',
      '',
      currentMemo
        ? `## 上一版备忘\n${currentMemo}`
        : '## 上一版备忘\n（还没写过——这是第一版）',
      '',
      '## 最近对话',
      transcript,
      '',
      '## 任务',
      '基于最近对话和上一版，写出新一版备忘。直接输出 markdown 正文，不要前言后语。',
      '如果实在没什么可记的，输出 [SILENT] 一个 token 即可（保留上一版不动）。',
    ].join('\n');

    const { result: completion, route, routeTrace } = await withFallback(
      supa,
      env,
      { modelSlug: bot.model_id as string, taskType: 'chat_memo' },
      (r) =>
        r.client.chat.completions.create({
          model: r.modelToCall,
          messages: [{ role: 'user', content: prompt }],
        }),
    );
    const raw = completion.choices[0]?.message?.content?.trim() ?? '';
    const action: 'silent' | 'update' = raw && raw !== '[SILENT]' ? 'update' : 'silent';
    await recordAudit(supa, route, {
      conversationId,
      taskType: 'chat_memo',
      startedAt,
      generationId: completion.id,
      status: 'success',
      routeTrace,
      metadata: { bot_id: botId, action },
      ...usageFromCompletion(completion.usage),
    });
    if (action === 'silent') return;

    if (existing?.id) {
      await supa
        .from('skills')
        .update({ body_md: raw, updated_at: new Date().toISOString() })
        .eq('id', existing.id);
    } else {
      await supa.from('skills').insert({
        owner_id: null,
        bot_id: botId,
        user_id: null,
        conversation_id: conversationId,
        visibility: 'private',
        frontmatter: {
          name: `chat-memo:${botId.slice(0, 8)}/${conversationId.slice(0, 8)}`,
          description: 'Bot private chat memo for this conversation',
        },
        body_md: raw,
      } as never);
    }
  } catch (err) {
    console.warn('[memory] refreshChatMemo failed', err);
    if (err instanceof FallbackError) {
      const supa = serviceClient(env);
      await recordAudit(supa, err.lastRoute, {
        conversationId,
        taskType: 'chat_memo',
        startedAt,
        status: 'error',
        errorClass:
          err.routeTrace[err.routeTrace.length - 1]?.error_class ?? 'unknown',
        routeTrace: err.routeTrace,
        metadata: { bot_id: botId, action: 'error' },
      });
    }
  }
}

/// Look up the chat-memo body for a conversation, if any. Used by the bot
/// reply path to inject it into the system prompt. Service-role read.
export async function getChatMemo(
  env: Env,
  botId: string,
  conversationId: string,
): Promise<string | null> {
  const supa = serviceClient(env);
  const { data } = await supa
    .from('skills')
    .select('body_md' as never)
    .eq('bot_id', botId)
    .eq('conversation_id' as never, conversationId)
    .is('user_id', null)
    .maybeSingle<{ body_md: string }>();
  return data?.body_md?.trim() || null;
}

// Returns true if `oldestContextId` is strictly newer than `coveredId`. Null
// covered means "never refreshed yet, definitely need to".
function needsCatchUp(coveredId: string | null, oldestContextId: string): boolean {
  if (!coveredId) return true;
  // UUIDv7 is monotonic — lexical compare on the hex form preserves order.
  return oldestContextId > coveredId;
}
