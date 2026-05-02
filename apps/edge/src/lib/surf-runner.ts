import type { Env } from '../types';
import { serviceClient } from './supabase';

// Surf agent runner — placeholder.
//
// The B7.4 Jina-based agent loop was reverted at user direction; the user
// will design + write the surf logic themselves. This stub:
//   1. flips surf_runs.status='running' → 'done' immediately
//   2. records the requested query in progress so the row isn't blank
//   3. emits no log messages (UI will show an empty timeline)
//
// Replace the body of runSurf with the real loop when the design is ready.
// Routes (POST /v1/surf/start, /:id/cancel) and the surf_runs schema stay
// unchanged — only the runner contents are stubbed.

export interface RunSurfInput {
  env: Env;
  surfRunId: string;
  conversationId: string;
  userId: string;
  query: string;
}

export async function runSurf(input: RunSurfInput): Promise<void> {
  const { env, surfRunId, query } = input;
  const supa = serviceClient(env);

  await supa
    .from('surf_runs')
    .update({
      status: 'done',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      progress: { phase: 'placeholder', query, note: 'surf agent loop pending design' },
    })
    .eq('id', surfRunId);
}
