import {
  resolveRoute,
  enqueueAudit,
  usageFromCompletion,
} from './router';
import type { ChatCompletionCreateParamsNonStreaming } from 'openai/resources/chat/completions';
import { serviceClient } from '../lib/supabase';
import { estimateTokens } from './token-estimate';
import { loadPrompt } from '../i18n/prompts';
import { uuidv7 } from '../lib/ids';
import { getModelRole } from '../lib/model-roles';
import type { Env } from '../types';

// Small-model classifier that decides which bots to wake on a group
// turn. Returns a list of bot ids in order of relevance (first ⇒
// most relevant; the dispatcher takes them serially).
//
// Why JSON output and not function-calling: per the planning doc,
// registering each member as a tool blows up the prompt at scale (a
// 100-member group means ~100 tool schemas) AND small models do
// "pick from a list" much better than parallel tool calling. A single
// JSON response with `{wake_bots: [...]}` keeps the schema tiny and
// lets the router run on cheap Gemma-class models.
//
// Model selection: a per-group override
// (`conversation_group_meta.router_model_slug`) wins when set; otherwise
// the groupRouter model-role baseline — a cheap small model that's plenty
// for the "pick from a list" classification.

export interface GroupRouterInput {
  env: Env;
  conversationId: string;
  /// Messages to consider — typically the post-lastRoutedAt window
  /// the DO collects. The router prioritizes the most recent messages
  /// and trims the prompt by token budget so it fits any small model.
  recentMessages: Array<{
    id: string;
    role: 'user' | 'bot' | 'human' | 'log';
    sender_label: string;   // nickname or display_name
    content: string;
  }>;
}

export interface GroupRouterDecision {
  wakeBots: string[];
  rationale: string;
  /// audit_log.id of the routing call itself. Persisted audit billing
  /// resolves the split from the conversation id.
  auditLogId: string | null;
}

const PROMPT_BUDGET_TOKENS = 2000;

export async function runGroupRouter(
  input: GroupRouterInput,
): Promise<GroupRouterDecision> {
  const { env, conversationId } = input;
  const supa = serviceClient(env);

  // 1. Resolve the small-model slug. Order:
  //    a. conversation_group_meta.router_model_slug (per-group)
  //    b. model-roles 'groupRouter' default (board-configurable)
  let modelSlug: string | null = null;

  const { data: meta } = await supa
    .from('conversation_group_meta')
    .select('router_model_slug')
    .eq('conversation_id', conversationId)
    .maybeSingle();
  if (meta?.router_model_slug) modelSlug = meta.router_model_slug;

  if (!modelSlug) modelSlug = await getModelRole(env, 'groupRouter');

  // 2. Pull bot members + per-group descriptions. Bots without a
  //    description (haven't introduced themselves yet — M5 fills this)
  //    fall back to display_name only. We do this in three reads
  //    because conversation_participants.participant_id has no formal
  //    FK to bots.id (it's a polymorphic column over user/bot), so
  //    supabase-js can't auto-join.
  const activeBots: Array<{ id: string; label: string; description: string }> = [];

  const { data: parts } = await supa
    .from('conversation_participants')
    .select('participant_id, nickname')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'bot');

  if (parts && parts.length > 0) {
    const botIds = parts.map((b) => b.participant_id as string);
    const [{ data: bots }, { data: descs }] = await Promise.all([
      supa
        .from('bots')
        .select('id, display_name, is_active')
        .in('id', botIds),
      supa
        .from('group_bot_descriptions')
        .select('bot_id, description')
        .eq('conversation_id', conversationId)
        .in('bot_id', botIds),
    ]);
    const botMap = new Map(
      (bots ?? []).map((b) => [b.id as string, b]),
    );
    const descMap = new Map(
      (descs ?? []).map((d) => [d.bot_id as string, d.description as string]),
    );
    const nicknameMap = new Map(
      parts.map((p) => [p.participant_id as string, p.nickname as string | null]),
    );

    for (const id of botIds) {
      const bot = botMap.get(id);
      if (!bot || !bot.is_active) continue;
      const label = nicknameMap.get(id) || (bot.display_name as string);
      const description = descMap.get(id) ?? '(尚未提交描述)';
      activeBots.push({ id, label, description });
    }
  }

  if (activeBots.length === 0) {
    return { wakeBots: [], rationale: 'no active bots in group', auditLogId: null };
  }

  // 3. Build the prompt. Trim recent messages from the tail until we
  //    fit the token budget.
  const trimmed: typeof input.recentMessages = [];
  let used = 0;
  for (let i = input.recentMessages.length - 1; i >= 0; i--) {
    const m = input.recentMessages[i];
    const t = estimateTokens(`${m.sender_label}: ${m.content}`);
    if (used + t > PROMPT_BUDGET_TOKENS) break;
    used += t;
    trimmed.unshift(m);
  }

  const conversationTranscript = trimmed
    .map((m) => `${m.sender_label}: ${m.content.slice(0, 500)}`)
    .join('\n');

  const botCatalog = activeBots
    .map((b) => `- ${b.label} (id=${b.id}): ${b.description}`)
    .join('\n');

  // prompt template lives in prompts/zh/group-router.md (or Langfuse
  // override); split on the `\n\n---\n\n` boundary into system + user halves.
  // Group router runs against the whole group so we use DEFAULT_LOCALE
  // here — per-user locale would require picking one participant.
  const groupRouterPrompt = await loadPrompt(env, 'group-router');
  const [systemPart, userTemplate] = groupRouterPrompt.split(/\n---\n/);
  const systemPrompt = systemPart.trim();
  const userPrompt = userTemplate
    .trim()
    .replace('{{conversationTranscript}}', conversationTranscript || '(无)')
    .replace('{{botCatalog}}', botCatalog);

  // 4. Call the LLM. We use the same router pipeline as bot-reply so
  //    audit_log + cost get computed identically.
  const startedAt = Date.now();
  const turnId = uuidv7();
  let route;
  try {
    route = await resolveRoute(supa, env, {
      modelSlug,
      taskType: 'group_router',
      metadata: { conversationId, turnId },
    });
  } catch (err) {
    console.error('[group-router] resolveRoute failed', err);
    return { wakeBots: [], rationale: `route error: ${err}`, auditLogId: null };
  }

  let decision: { wake_bots: unknown; rationale: unknown } | null = null;
  let inputTokens = 0;
  let outputTokens = 0;
  let auditLogId: string | null = null;
  try {
    const request = {
      model: route.modelToCall,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt },
      ],
      response_format: { type: 'json_object' },
      temperature: 0.2,
      max_tokens: 400,
    } as ChatCompletionCreateParamsNonStreaming;
    const completion = await route.client.chat.completions.create(request);
    const usage = usageFromCompletion(completion.usage, completion);
    inputTokens = usage.inputTokens ?? 0;
    outputTokens = usage.outputTokens ?? 0;

    const raw = completion.choices?.[0]?.message?.content ?? '';
    try {
      decision = JSON.parse(raw);
    } catch (err) {
      console.warn('[group-router] non-JSON response from small model', {
        length: raw.length,
        error: (err as Error)?.name ?? 'parse_error',
      });
    }

    auditLogId = await enqueueAudit(env, route, {
      auditId: turnId,
      conversationId,
      taskType: 'group_router',
      startedAt,
      inputTokens,
      outputTokens,
      status: 'success',
      ...usage,
    });
  } catch (err) {
    console.error('[group-router] LLM call failed', err);
    await enqueueAudit(env, route, {
      auditId: turnId,
      conversationId,
      taskType: 'group_router',
      startedAt,
      status: 'error',
      errorClass: err instanceof Error ? err.name : 'unknown',
    });
    return { wakeBots: [], rationale: 'classifier error', auditLogId: null };
  }

  // 5. Validate the model's output. We accept arrays of strings;
  //    everything else is treated as "no wake" so a bad response
  //    doesn't accidentally wake every bot.
  const validIds = new Set(activeBots.map((b) => b.id));
  let wakeBots: string[] = [];
  if (decision && Array.isArray(decision.wake_bots)) {
    wakeBots = (decision.wake_bots as unknown[])
      .filter((x): x is string => typeof x === 'string' && validIds.has(x));
  }
  const rationale =
    typeof decision?.rationale === 'string' ? decision.rationale : '(no rationale)';

  return { wakeBots, rationale, auditLogId };
}
