import type { Env } from '../types';

// Honcho memory cache backed by CF Workers KV. Two key namespaces:
//   user:${userId}  — derived "what bots see in this user" (transparency UI only)
//   bot:${botId}    — bot self-representation (injected into bot's system prompt)
//
// Cache fills async after each bot turn (`ctx.waitUntil(refreshBotMemory(...))`).
// Reads on the LLM hot path; eventual consistency 10-60s is fine — Honcho
// representations evolve slowly and approximation is the point.

export interface Memory {
  card: string[];
  representation: string;
  syncedAt: string; // ISO 8601
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

// Refresh hooks — call from `ctx.waitUntil(...)` after each bot turn.
// Implementations call Honcho's getUserProfile and write KV. Stubbed for now;
// real impl lands in B7.
export async function refreshUserMemory(_env: Env, _userId: string): Promise<void> {
  // TODO(B7): call honcho.peer(userPeerId).context() and put to KV
}

export async function refreshBotMemory(_env: Env, _botId: string): Promise<void> {
  // TODO(B7): call honcho.peer(botPeerId).context() and put to KV
}
