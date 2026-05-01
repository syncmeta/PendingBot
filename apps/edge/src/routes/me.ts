import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { getUserMemory } from '../lib/memory';
import type { AppBindings } from '../types';

export const meRoutes = new Hono<AppBindings>();
meRoutes.use('*', requireSession());

// GET /v1/me/memory — transparency UI: "what bots see in me".
// Backed by KV (Honcho user-peer representation, refreshed after each turn).
// Per plan/02 this is the ONLY surface that exposes user representation —
// it's never injected into any bot's system prompt.
meRoutes.get('/memory', async (c) => {
  const userId = c.var.userId!;
  const memory = await getUserMemory(c.env, userId);
  if (!memory) {
    return c.json({ card: [], representation: '', syncedAt: null });
  }
  return c.json(memory);
});
