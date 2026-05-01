import type { Env } from '../types';
import { honchoClient, userPeerId, botPeerId, conversationSessionId } from './honcho';
import { serviceClient } from './supabase';

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
  } catch (err) {
    console.warn('[memory] maybeRefresh failed', err);
  }
}

// Returns true if `oldestContextId` is strictly newer than `coveredId`. Null
// covered means "never refreshed yet, definitely need to".
function needsCatchUp(coveredId: string | null, oldestContextId: string): boolean {
  if (!coveredId) return true;
  // UUIDv7 is monotonic — lexical compare on the hex form preserves order.
  return oldestContextId > coveredId;
}
