import type { Env } from '../types';
import { honchoClient, userPeerId, botPeerId } from './honcho';

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
// Each peeks the live representation from Honcho, normalizes it, and overwrites
// KV. Failure leaves the previous KV value intact (best-effort cache; never
// blocks the LLM hot path).

async function refreshFromHoncho(
  env: Env,
  kvKey: string,
  peerId: string,
): Promise<void> {
  try {
    const honcho = honchoClient(env);
    const peer = await honcho.peer(peerId);
    const ctx = await peer.context();
    const memory: Memory = {
      card: ctx.peerCard ?? [],
      representation: ctx.representation ?? '',
      syncedAt: new Date().toISOString(),
    };
    await env.MEMORY.put(kvKey, JSON.stringify(memory));
  } catch (err) {
    // Honcho hiccups shouldn't poison the cache. Old value stays.
    console.warn('[memory] refresh failed', { kvKey, err: String(err) });
  }
}

export async function refreshUserMemory(env: Env, userId: string): Promise<void> {
  await refreshFromHoncho(env, USER_PREFIX + userId, userPeerId(userId));
}

export async function refreshBotMemory(env: Env, botId: string): Promise<void> {
  await refreshFromHoncho(env, BOT_PREFIX + botId, botPeerId(botId));
}
