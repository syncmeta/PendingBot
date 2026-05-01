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
