import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { resolveConv } from '../lib/conv-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { computeLeaderboard, type Outcome } from '../lib/arena-elo';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

// Arena: pairwise blind voting + a per-user model leaderboard (类 arena.ai).
//
//   POST /v1/arena/compare       — record one A/B vote
//   GET  /v1/arena/leaderboard   — replay Elo over the caller's votes
//
// Blindness is enforced client-side (the picker hides the model name until
// the vote lands) — this is a single-user personal-preference dataset, so
// the only integrity risk is the user peeking at their own data, which only
// degrades their own leaderboard. The compare response reveals the models so
// the UI can show them post-vote.

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

  // Reveal map keyed by the ORIGINAL group ids the client showed, before
  // we normalise pair ordering below.
  const reveal: Record<string, { model_slug: string; model_provider: string | null }> = {
    [parsed.groupA]: { model_slug: mA.model_slug, model_provider: mA.model_provider },
    [parsed.groupB]: { model_slug: mB.model_slug, model_provider: mB.model_provider },
  };

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

  return c.json({ ok: true, models: reveal });
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
