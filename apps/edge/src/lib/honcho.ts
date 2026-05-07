import { Honcho } from '@honcho-ai/sdk';
import type { Env } from '../types';

// Single Honcho client per request. SDK is stateless aside from auth/workspace
// config; instantiating per call is cheap and keeps the dependency contained
// to this module so the rest of the codebase doesn't import @honcho-ai/sdk.

export function honchoClient(env: Env): Honcho {
  return new Honcho({
    apiKey: env.HONCHO_API_KEY,
    workspaceId: env.HONCHO_WORKSPACE_ID,
  });
}

// Peer naming convention from plan/02:
//   user-${userId}   user peer (observe_me=true → user representation)
//   bot-${botId}     bot peer (observe_me=true → bot self representation)
//   conv-${convId}   session, scoped to user peer ∪ bot peer
export const userPeerId = (userId: string): string => `user-${userId}`;
export const botPeerId = (botId: string): string => `bot-${botId}`;
export const conversationSessionId = (convId: string): string => `conv-${convId}`;

export interface QueryUserOptions {
  env: Env;
  userId: string;
  /// Scope the dialectic call to this conversation's session so the answer
  /// reflects only what's been said in this thread. Omit (undefined) to query
  /// across all sessions the user peer participates in.
  conversationId?: string;
  query: string;
  signal?: AbortSignal;
}

/// Ask Honcho's dialectic endpoint a natural-language question about the user.
/// The dialectic agent does retrieval + reasoning over everything observed
/// about the peer (conclusions, raw messages, peer card) and returns a
/// grounded answer. Returns null when Honcho has nothing to say.
export async function queryUserRepresentation(
  opts: QueryUserOptions,
): Promise<string | null> {
  const { env, userId, conversationId, query, signal } = opts;
  const honcho = honchoClient(env);
  const peer = await honcho.peer(userPeerId(userId));
  // SDK v2: peer.chat(query, { sessionId? }) returns { content: string | null }.
  // We don't pipe AbortSignal through (SDK doesn't accept one); the dialectic
  // call is bounded server-side, and this tool is invoked inside an agent loop
  // whose outer abort flips the model's stream — a stale dialectic in flight
  // is harmless.
  void signal;
  const content = await peer.chat(query, conversationId
    ? { session: conversationSessionId(conversationId) }
    : undefined);
  return content?.trim() || null;
}
