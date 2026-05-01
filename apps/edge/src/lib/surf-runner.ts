import { randomUUID } from 'node:crypto';
import type { Env } from '../types';
import { serviceClient } from './supabase';

// Surf agent runner.
//
// B6: scaffold only — drives the Realtime wiring (surf_runs status + log
// messages with log_kind='surf:step' / 'surf:result'). The actual web search
// + URL fetch + reasoning loop lands in B7 alongside Daytona for code-exec
// tools.
//
// The contract this stub honors:
//   1. Caller has already INSERTed surf_runs(status='running').
//   2. We emit at least one role='log' step message into the conv so any
//      subscriber to the conv channel sees it (Realtime smoke).
//   3. We finalize surf_runs.status to 'done' or 'error'. Never leaves
//      'running' on a normal exit.

export interface RunSurfInput {
  env: Env;
  surfRunId: string;
  conversationId: string;
  userId: string;
  query: string;
}

async function emitLog(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  surfRunId: string,
  step: string,
  status: 'running' | 'done' | 'error',
  detail?: Record<string, unknown>,
): Promise<void> {
  await supa.from('messages').insert({
    client_message_id: randomUUID(),
    conversation_id: conversationId,
    role: 'log',
    status: 'done',
    log_kind: 'surf:step',
    log_payload: { surf_run_id: surfRunId, step, status, ...(detail ?? {}) },
  });
}

export async function runSurf(input: RunSurfInput): Promise<void> {
  const { env, surfRunId, conversationId, query } = input;
  const supa = serviceClient(env);
  const startedAt = new Date().toISOString();

  await supa
    .from('surf_runs')
    .update({ started_at: startedAt, progress: { phase: 'starting', query } })
    .eq('id', surfRunId);

  try {
    // TODO(B7): real agent loop:
    //   1. plan: LLM decides which tools (web search / read url / run code)
    //   2. iterate: emit surf:step running → tool call → surf:step done
    //   3. summarize: emit surf:result with final synthesis
    //   4. update surf_runs.cost_used_usd from accumulated audit_log rows
    //
    // For now we emit a single placeholder so the Realtime channel proves out.
    await emitLog(supa, conversationId, surfRunId, 'placeholder', 'running', {
      label: 'Surf is scaffolded — agent loop lands in B7',
    });
    await emitLog(supa, conversationId, surfRunId, 'placeholder', 'done');

    await supa
      .from('surf_runs')
      .update({
        status: 'done',
        finished_at: new Date().toISOString(),
        progress: { phase: 'done', query },
      })
      .eq('id', surfRunId);
  } catch (err) {
    console.error('[surf-runner]', err);
    await supa
      .from('surf_runs')
      .update({
        status: 'error',
        finished_at: new Date().toISOString(),
        progress: { phase: 'error', error: String(err) },
      })
      .eq('id', surfRunId);
  }
}
