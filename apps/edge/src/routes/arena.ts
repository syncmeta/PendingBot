import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { deleteCachedConv, resolveConv } from '../lib/conv-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { computeLeaderboard, type Outcome } from '../lib/arena-bradley-terry';
import { recordScore } from '../lib/llm-trace';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

// Pairwise blind choice + a per-user model leaderboard.
//
//   POST /v1/arena/compare       — record one A/B vote
//   GET  /v1/arena/leaderboard   — Bradley-Terry fit over the caller's votes
//
// Blindness is enforced client-side; choosing A/B also switches the current
// conversation main model to the chosen answer's model. The response does not
// reveal model identity to the client.

export const arenaRoutes = new Hono<AppBindings>();
arenaRoutes.use('*', requireSession());

const CompareBody = z.object({
  conversationId: z.string().uuid(),
  parentMessageId: z.string().uuid(),
  // bubble_group_id of each answer being compared (one prompt's variants
  // share parent_message_id; each answer is one bubble_group_id).
  groupA: z.string().uuid(),
  groupB: z.string().uuid(),
  outcome: z.enum(['a', 'b', 'tie']),
});

interface GroupModel {
  model_slug: string;
  model_provider: string | null;
  parent_message_id: string | null;
  conversation_id: string;
}

export function modelSwitchForOutcome(
  outcome: Outcome,
  modelA: GroupModel,
  modelB: GroupModel,
): { model_slug: string; model_provider: string | null } | null {
  if (outcome === 'a') {
    return { model_slug: modelA.model_slug, model_provider: modelA.model_provider };
  }
  if (outcome === 'b') {
    return { model_slug: modelB.model_slug, model_provider: modelB.model_provider };
  }
  return null;
}

arenaRoutes.post('/compare', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof CompareBody>;
  try {
    parsed = CompareBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  if (parsed.groupA === parsed.groupB) {
    return jsonError(c, 400, 'invalid_body', { message: '不能和自己比较' });
  }

  const supaUser = userClient(c.env, userJwt);
  const supaService = serviceClient(c.env);

  // Membership gate — caller must be a participant of the conversation.
  const conv = await resolveConv(c.env, supaUser, parsed.conversationId, userId, (p) =>
    safeWaitUntil(c, p),
  ).catch(() => null);
  if (!conv) return jsonError(c, 404, 'conversation_no_access');

  // Resolve the model behind each bubble group. Take any bot row of the
  // group — all rows of one answer carry the same model_slug.
  const groupModel = async (groupId: string): Promise<GroupModel | null> => {
    const { data } = await supaService
      .from('messages')
      .select('model_slug, model_provider, parent_message_id, conversation_id')
      .eq('bubble_group_id', groupId)
      .eq('role', 'bot')
      .not('model_slug', 'is', null)
      .limit(1)
      .maybeSingle();
    if (!data || !data.model_slug) return null;
    return {
      model_slug: data.model_slug,
      model_provider: (data.model_provider ?? null) as string | null,
      parent_message_id: (data.parent_message_id ?? null) as string | null,
      conversation_id: data.conversation_id as string,
    };
  };

  const [mA, mB] = await Promise.all([groupModel(parsed.groupA), groupModel(parsed.groupB)]);
  if (!mA || !mB) {
    return jsonError(c, 404, 'not_found', { message: '回答不存在或未记录模型' });
  }
  // Both answers must be variants of the named prompt in this conversation —
  // stops a caller from stitching together a comparison across prompts.
  for (const m of [mA, mB]) {
    if (m.conversation_id !== parsed.conversationId || m.parent_message_id !== parsed.parentMessageId) {
      return jsonError(c, 400, 'invalid_body', { message: '回答不属于该 prompt' });
    }
  }

  const selectedModel = modelSwitchForOutcome(parsed.outcome, mA, mB);

  // Normalise so the unordered pair maps to one row: store the lexically
  // smaller group id as A, flipping the outcome to match. Makes a re-vote
  // idempotent regardless of which side the UI happened to show as A.
  let gA = parsed.groupA;
  let gB = parsed.groupB;
  let pA = mA;
  let pB = mB;
  let outcome: Outcome = parsed.outcome;
  if (gA > gB) {
    [gA, gB] = [gB, gA];
    [pA, pB] = [pB, pA];
    outcome = parsed.outcome === 'a' ? 'b' : parsed.outcome === 'b' ? 'a' : 'tie';
  }

  const { error } = await supaService.from('model_comparisons').upsert(
    {
      user_id: userId,
      conversation_id: parsed.conversationId,
      parent_message_id: parsed.parentMessageId,
      group_a_id: gA,
      group_b_id: gB,
      model_a: pA.model_slug,
      model_b: pB.model_slug,
      provider_a: pA.model_provider,
      provider_b: pB.model_provider,
      outcome,
    },
    { onConflict: 'user_id,group_a_id,group_b_id' },
  );
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });

  if (selectedModel) {
    const { error: switchErr } = await supaService
      .from('conversations')
      .update({
        current_model_slug: selectedModel.model_slug,
        current_model_provider: selectedModel.model_provider ?? 'openrouter',
      })
      .eq('id', parsed.conversationId);
    if (switchErr) return jsonError(c, 500, 'database_error', { detail: switchErr.message });
    await deleteCachedConv(c.env, parsed.conversationId).catch(() => undefined);
  }

  // Feed the preference vote into Langfuse as a score (#249). Numeric value
  // is from model_a's perspective on the normalised pair: a=1 (A preferred),
  // tie=0.5, b=0 — so averaging the score across many votes for a pair reads
  // as A's win rate. The categorical winner + slugs ride in the comment for
  // human-readable filtering. Deterministic traceId per (user, pair) so a
  // re-vote updates the same trace's score rather than piling up duplicates,
  // matching the idempotent DB upsert above. Best-effort + off-path.
  const scoreValue = outcome === 'a' ? 1 : outcome === 'tie' ? 0.5 : 0;
  safeWaitUntil(
    c,
    recordScore(c.env, {
      name: 'arena_preference',
      value: scoreValue,
      dataType: 'NUMERIC',
      traceId: `arena:${userId}:${gA}:${gB}`,
      traceName: 'arena_vote',
      userId,
      sessionId: parsed.conversationId,
      comment: `winner=${outcome} a=${pA.model_slug} b=${pB.model_slug}`,
      metadata: {
        model_a: pA.model_slug,
        model_b: pB.model_slug,
        provider_a: pA.model_provider,
        provider_b: pB.model_provider,
        outcome,
        conversation_id: parsed.conversationId,
        parent_message_id: parsed.parentMessageId,
      },
    }),
  );

  return c.json({ ok: true });
});

// GET /v1/arena/leaderboard — the caller's personal model standings.
arenaRoutes.get('/leaderboard', async (c) => {
  const userId = c.var.userId!;
  const supaService = serviceClient(c.env);

  const { data, error } = await supaService
    .from('model_comparisons')
    .select('model_a, model_b, outcome, created_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: true });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });

  const comparisons = (data ?? []).map((r) => ({
    model_a: r.model_a as string,
    model_b: r.model_b as string,
    outcome: r.outcome as Outcome,
  }));
  const standings = computeLeaderboard(comparisons);
  return c.json({ standings, total_comparisons: comparisons.length });
});
