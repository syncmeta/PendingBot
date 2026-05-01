import { randomUUID } from 'node:crypto';
import type { Env } from '../types';
import { serviceClient } from './supabase';

// Review agent runner.
//
// B6: scaffold — emits the canonical 3-message review shape (step → card →
// closing) into the host message conversation, so any client subscribed to
// the conv channel renders the special log bubbles. Real review LLM logic
// (3-prompt chain + bot_reflections persistence) lands in B7.
//
// Contract:
//   1. Caller has INSERTed review_runs(status='running') and we own the
//      remaining lifecycle.
//   2. All surface to the user is via role='log' messages in the SAME
//      conversation as the original chat (see plan/03 — review integrated).
//   3. Finalize status to 'done' or 'error'.

export interface RunReviewInput {
  env: Env;
  reviewRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
}

async function emitLog(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  reviewRunId: string,
  log_kind: 'review:step' | 'review:card' | 'review:closing',
  payload: Record<string, unknown>,
): Promise<void> {
  await supa.from('messages').insert({
    client_message_id: randomUUID(),
    conversation_id: conversationId,
    role: 'log',
    status: 'done',
    log_kind,
    log_payload: { review_run_id: reviewRunId, ...payload },
  });
}

export async function runReview(input: RunReviewInput): Promise<void> {
  const { env, reviewRunId, conversationId } = input;
  const supa = serviceClient(env);

  await supa
    .from('review_runs')
    .update({ started_at: new Date().toISOString() })
    .eq('id', reviewRunId);

  try {
    // TODO(B7): real review chain:
    //   1. emit review:step{ step:'gather', status:'running' }
    //   2. fetch last N messages, prompt eval.md → got 3-bucket reflections
    //   3. emit review:step done; emit review:card×2 (you + me)
    //   4. prompt followup.md → emit review:closing
    //   5. INSERT bot_reflections rows (kind=limit/grow/keep)
    //
    // Stub here just emits the shape so UI can be built before B7 lands.
    await emitLog(supa, conversationId, reviewRunId, 'review:step', {
      step: 'placeholder',
      label: 'Review scaffolded',
      status: 'done',
    });
    await emitLog(supa, conversationId, reviewRunId, 'review:closing', {
      mode: 'note',
      content: 'Review pipeline lands in B7.',
    });

    await supa
      .from('review_runs')
      .update({ status: 'done', finished_at: new Date().toISOString() })
      .eq('id', reviewRunId);
  } catch (err) {
    console.error('[review-runner]', err);
    await supa
      .from('review_runs')
      .update({ status: 'error', finished_at: new Date().toISOString() })
      .eq('id', reviewRunId);
  }
}
