import { resolveRoute, recordAudit, usageFromCompletion } from './router';
import type { ProviderUsageDetails } from './provider-usage';
import { serviceClient } from '../lib/supabase';
import { estimateTokens } from './token-estimate';
import { splitAndDebit } from '../lib/group-billing';
import { getMarkup, usdToPnd } from '../lib/billing';
import { loadPrompt } from '../i18n/prompts';
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
// Model selection: task_type='group_router' lookup (seeded in 0043).
// Per-group override (`conversation_group_meta.router_model_slug`)
// trumps the task_routing_rules row when set; the worker resolves the
// effective slug here before calling resolveRoute.

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
  /// audit_log.id of the routing call itself, so callers can split
  /// THIS call's cost too (M6).
  auditLogId: string | null;
}

const PROMPT_BUDGET_TOKENS = 2000;
const FALLBACK_MODEL_SLUG = 'google/gemma-3-27b-it';

export async function runGroupRouter(
  input: GroupRouterInput,
): Promise<GroupRouterDecision> {
  const { env, conversationId } = input;
  const supa = serviceClient(env);

  // 1. Resolve the small-model slug. Order:
  //    a. conversation_group_meta.router_model_slug (per-group)
  //    b. task_routing_rules('group_router').override_model.slug (global)
  //    c. FALLBACK_MODEL_SLUG hardcoded baseline
  let modelSlug: string | null = null;

  const { data: meta } = await supa
    .from('conversation_group_meta')
    .select('router_model_slug')
    .eq('conversation_id', conversationId)
    .maybeSingle();
  if (meta?.router_model_slug) modelSlug = meta.router_model_slug;

  if (!modelSlug) {
    // resolveRoute consults task_routing_rules itself, but only when
    // we already have a slug to start with. Read the rule directly so
    // we get the override slug to pass in.
    const { data: rule } = await supa
      .from('task_routing_rules')
      .select(
        `override_model:llm_models!task_routing_rules_override_model_fkey ( slug )`,
      )
      .eq('task_type', 'group_router')
      .eq('enabled', true)
      .order('match_priority', { ascending: true })
      .limit(1)
      .maybeSingle();
    const ruleSlug = (rule?.override_model as { slug?: string } | null)?.slug;
    if (ruleSlug) modelSlug = ruleSlug;
  }

  if (!modelSlug) modelSlug = FALLBACK_MODEL_SLUG;

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

  // prompt template lives in prompts/zh/group-router.md (or DB override);
  // split on the `\n\n---\n\n` boundary into system + user halves.
  // Group router runs against the whole group so we use DEFAULT_LOCALE
  // here — per-user locale would require picking one participant.
  const groupRouterPrompt = await loadPrompt(supa, 'group-router');
  const [systemPart, userTemplate] = groupRouterPrompt.split(/\n---\n/);
  const systemPrompt = systemPart.trim();
  const userPrompt = userTemplate
    .trim()
    .replace('{{conversationTranscript}}', conversationTranscript || '(无)')
    .replace('{{botCatalog}}', botCatalog);

  // 4. Call the LLM. We use the same router pipeline as bot-reply so
  //    audit_log + cost get computed identically.
  const startedAt = Date.now();
  let route;
  try {
    route = await resolveRoute(supa, env, {
      modelSlug,
      taskType: 'group_router',
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
    const completion = await route.client.chat.completions.create({
      model: route.modelToCall,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt },
      ],
      response_format: { type: 'json_object' },
      temperature: 0.2,
      max_tokens: 400,
    });
    const usage = usageFromCompletion(completion.usage, completion);
    inputTokens = usage.inputTokens ?? 0;
    outputTokens = usage.outputTokens ?? 0;

    const raw = completion.choices?.[0]?.message?.content ?? '';
    try {
      decision = JSON.parse(raw);
    } catch (err) {
      console.warn('[group-router] non-JSON response from small model', raw, err);
    }

    auditLogId = await writeAuditAndGetId(supa, route, {
      conversationId,
      startedAt,
      inputTokens,
      outputTokens,
      providerUsage: usage,
      status: 'success',
    });
    if (auditLogId) {
      await splitAndDebit({ env, auditLogId }).catch((err) =>
        console.warn('[group-router] splitAndDebit failed', err),
      );
    }
  } catch (err) {
    console.error('[group-router] LLM call failed', err);
    await recordAudit(supa, route, {
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

// recordAudit returns void; we need the inserted row's id for cost
// splitting in M6. Bypass and write the row directly with the same
// shape recordAudit produces, then return id.
async function writeAuditAndGetId(
  supa: ReturnType<typeof serviceClient>,
  route: Awaited<ReturnType<typeof resolveRoute>>,
  opts: {
    conversationId: string;
    startedAt: number;
    inputTokens: number;
    outputTokens: number;
    providerUsage?: ProviderUsageDetails;
    status: 'success' | 'error';
  },
): Promise<string | null> {
  const total = opts.inputTokens + opts.outputTokens;
  const estimatedCost = route.alias
    ? computeRouterCost(route.alias, opts.inputTokens, opts.outputTokens)
    : null;
  const cost = opts.providerUsage?.providerCostUsd ?? null;
  const markup = await getMarkup(supa);
  const pnd = usdToPnd(cost, markup);
  const { data, error } = await supa
    .from('audit_log')
    .insert({
      conversation_id: opts.conversationId,
      task_type: 'group_router',
      model_id: route.modelToCall,
      provider_id: route.provider.id,
      model_alias_id: route.alias?.aliasId ?? null,
      input_tokens: opts.inputTokens,
      output_tokens: opts.outputTokens,
      total_tokens: total,
      cost_usd: cost,
      estimated_cost_usd: estimatedCost,
      reported_provider: opts.providerUsage?.reportedProvider ?? null,
      cost_details: opts.providerUsage?.costDetails ?? null,
      prompt_tokens_details: opts.providerUsage?.promptTokensDetails ?? null,
      completion_tokens_details: opts.providerUsage?.completionTokensDetails ?? null,
      // splitAndDebit reads cost_credits — must be filled at insert
      // time, not after.
      cost_credits: pnd,
      latency_ms: Date.now() - opts.startedAt,
      status: opts.status,
      // Pre-billing: leave billing_status='pending'; splitAndDebit
      // flips it to 'billed' / 'unbilled' / 'free' once split rows land.
      billing_status: 'pending',
    })
    .select('id')
    .single();
  if (error || !data) {
    console.error('[group-router] audit_log insert failed', error);
    return null;
  }
  return data.id as string;
}

function computeRouterCost(
  alias: { inputPrice: number | null; outputPrice: number | null },
  inputTokens: number,
  outputTokens: number,
): number | null {
  if (alias.inputPrice == null && alias.outputPrice == null) return null;
  const inCost = (alias.inputPrice ?? 0) * inputTokens / 1_000_000;
  const outCost = (alias.outputPrice ?? 0) * outputTokens / 1_000_000;
  return inCost + outCost;
}
