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
  botId: string;
  /// Only consulted for group turns — see `inGroup`.
  conversationId: string;
  /// Directional scoping of the dialectic call:
  ///   • Private turn (1v1 / self / sub-conversation, inGroup=false) →
  ///     no session scope. The bot draws on everything it has observed
  ///     about this user across *all* the sessions they share, so memory
  ///     follows the (bot, user) relationship rather than being trapped in
  ///     the current thread.
  ///   • Group turn (inGroup=true) → scope to this conversation's session,
  ///     so a bot replying in a multi-party room can't surface what the
  ///     user told it in a private 1v1 (cross-context leak).
  inGroup: boolean;
  query: string;
  signal?: AbortSignal;
}

/// Ask Honcho's dialectic endpoint what *this bot* knows about *this user*.
/// We query the bot peer's local representation of the user (theory-of-mind,
/// via `target`) rather than the user's global representation — that keeps
/// the answer bounded to the (bot, user) pair instead of bleeding in what
/// the user said to other bots. The dialectic agent does retrieval +
/// reasoning over the in-scope conclusions / raw messages / peer card and
/// returns a grounded answer, or null when it has nothing to say.
export async function queryUserRepresentation(
  opts: QueryUserOptions,
): Promise<string | null> {
  const { env, userId, botId, conversationId, inGroup, query, signal } = opts;
  // We don't pipe AbortSignal through (SDK doesn't accept one); the dialectic
  // call is bounded server-side, and this tool is invoked inside an agent loop
  // whose outer abort flips the model's stream — a stale dialectic in flight
  // is harmless.
  void signal;
  const honcho = honchoClient(env);
  const botPeer = await honcho.peer(botPeerId(botId));
  // SDK v2: peer.chat(query, { target, session? }) returns string | null.
  // target = the user peer → bot's local model of the user. Session is only
  // added for group turns (leak boundary); private turns stay unscoped so
  // recall pools across every conversation the pair shares.
  const content = await botPeer.chat(query, {
    target: userPeerId(userId),
    ...(inGroup ? { session: conversationSessionId(conversationId) } : {}),
  });
  return content?.trim() || null;
}
