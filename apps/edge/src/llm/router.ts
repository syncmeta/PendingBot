import OpenAI from 'openai';
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import type { Json } from '../db/schema';
import { billingDebit, getMarkup, usdToPnd } from '../lib/billing';
import { splitAndDebit } from '../lib/group-billing';
import type { WebToolUsage } from '../lib/web-meter';

// LLM router — resolves a caller-supplied model slug to a concrete
// (provider, alias) pair, hands back an OpenAI-compatible client
// pointed at that provider, and provides the central audit-log writer
// that records token usage and cost in a provider-aware way.
//
// Resolution order:
//   1. Exact hit on llm_models.slug (canonical name registered in admin
//      UI). Pick the highest-weight enabled alias for it.
//   2. Exact hit on llm_model_aliases.provider_model_id (legacy /
//      passthrough flow — bots that still hold a raw OpenRouter slug
//      like "anthropic/claude-opus-4.5" land here once the admin
//      registers that alias).
//   3. Fallback: assume OpenRouter passthrough — return the OpenRouter
//      provider with the slug used as-is. alias = null, so the audit row
//      records provider_id but no model_alias_id and no cost (we don't
//      know the price for an unregistered alias). This keeps the system
//      working in the gap between deploying the router and curating
//      every model in the admin UI.
//
// Secret access is dynamic: each provider names an env var via
// secret_ref (e.g. 'OPENROUTER_API_KEY'). We index env at runtime, which
// requires the Env interface in types.ts to declare every secret name a
// real provider row references — otherwise the worker will fail to read
// it. New providers added via the admin UI must be paired with a secret
// declared in wrangler.jsonc + Env type.

export interface RouteResolveOpts {
  modelSlug: string;
  // task_type that the caller will record in audit_log. When set, the
  // router consults task_routing_rules for an enabled rule matching
  // this task and may swap modelSlug / set preferProvider before doing
  // the alias lookup. Without it, no rule lookup runs.
  taskType?: string;
  // Bias selection toward this provider slug. Used by per-task routing
  // overrides ("ai_picks always uses openrouter") and by manual
  // operator pin-to-provider overrides. Caller-supplied wins over rule.
  preferProvider?: string;
  // Used by fallback retries: skip these provider slugs.
  excludeProviders?: string[];
}

export interface RouteAlias {
  aliasId: string;
  providerId: string;
  providerSlug: string;
  providerModelId: string;
  inputPrice: number | null;
  cachedInputPrice: number | null;
  outputPrice: number | null;
  cacheWritePrice: number | null;
  // Voice call pricing — per-1M audio token, populated on the alias that
  // backs the OpenAI Realtime path. Both null on text-only aliases.
  audioInputPrice: number | null;
  audioOutputPrice: number | null;
}

export interface ResolvedRoute {
  client: OpenAI;
  // The provider-specific id to put in completions.create({ model }).
  // For canonical/aliased routes this is alias.providerModelId; for the
  // OpenRouter passthrough fallback it's the raw slug the caller passed.
  modelToCall: string;
  alias: RouteAlias | null;
  provider: { id: string; slug: string };
}

export class NoRouteError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NoRouteError';
  }
}

// Internal: shape of the alias join result from supabase-js.
type AliasJoinRow = {
  id: string;
  provider_id: string;
  provider_model_id: string;
  weight: number;
  input_price: number | null;
  cached_input_price: number | null;
  output_price: number | null;
  cache_write_price: number | null;
  audio_input_price: number | null;
  audio_output_price: number | null;
  llm_providers:
    | {
        id: string;
        slug: string;
        base_url: string;
        auth_type: string;
        secret_ref: string;
        priority: number;
        enabled: boolean;
        config: unknown;
      }
    | null;
};

function pickAlias(
  rows: AliasJoinRow[],
  opts: { preferProvider?: string; excludeProviders?: string[] },
): AliasJoinRow | null {
  const candidates = rows.filter((r) => {
    const p = r.llm_providers;
    if (!p || !p.enabled) return false;
    if (opts.preferProvider && p.slug !== opts.preferProvider) return false;
    if (opts.excludeProviders?.includes(p.slug)) return false;
    return true;
  });
  if (candidates.length === 0) return null;
  // Highest weight wins; ties broken by provider.priority asc (lower =
  // preferred), then by alias id for stability.
  candidates.sort((a, b) => {
    if (b.weight !== a.weight) return b.weight - a.weight;
    const pa = a.llm_providers!.priority;
    const pb = b.llm_providers!.priority;
    if (pa !== pb) return pa - pb;
    return a.id.localeCompare(b.id);
  });
  return candidates[0]!;
}

function buildClient(
  env: Env,
  provider: { base_url: string; auth_type: string; secret_ref: string; config: unknown },
): OpenAI {
  const envBag = env as unknown as Record<string, string | undefined>;
  const apiKey = envBag[provider.secret_ref];
  if (!apiKey) {
    throw new NoRouteError(
      `provider secret_ref ${provider.secret_ref} is not bound on the worker — ` +
        `add it to wrangler.jsonc and Env type, or disable the provider in admin`,
    );
  }
  const cfg =
    provider.config && typeof provider.config === 'object' && !Array.isArray(provider.config)
      ? (provider.config as Record<string, unknown>)
      : {};
  const extraHeaders =
    (cfg.extra_headers as Record<string, string> | undefined) ?? {};
  return new OpenAI({
    apiKey,
    baseURL: provider.base_url,
    defaultHeaders: {
      'HTTP-Referer': 'https://pendingname.com',
      'X-Title': 'PendingBot',
      ...extraHeaders,
    },
  });
}

export async function resolveRoute(
  supa: SupabaseClient,
  env: Env,
  opts: RouteResolveOpts,
): Promise<ResolvedRoute> {
  let slug = opts.modelSlug.trim();
  if (!slug) throw new NoRouteError('empty model slug');
  let preferProvider = opts.preferProvider;

  // Per-task override pass. We pull the lowest-priority enabled rule
  // for this task_type — at most one applies. Caller-supplied
  // preferProvider wins over the rule (admin/incident overrides).
  if (opts.taskType) {
    const { data: rule } = await supa
      .from('task_routing_rules')
      .select(
        `match_priority, override_model_id, prefer_provider_id,
         override_model:llm_models!task_routing_rules_override_model_fkey ( slug ),
         prefer_provider:llm_providers!task_routing_rules_prefer_provider_fkey ( slug )`,
      )
      .eq('task_type', opts.taskType)
      .eq('enabled', true)
      .order('match_priority', { ascending: true })
      .limit(1)
      .maybeSingle();
    if (rule) {
      const overrideSlug = (rule.override_model as { slug?: string } | null)?.slug;
      if (overrideSlug) slug = overrideSlug;
      const ruleProvider = (rule.prefer_provider as { slug?: string } | null)?.slug;
      if (!preferProvider && ruleProvider) preferProvider = ruleProvider;
    }
  }

  // Step 1 + 2: pull all aliases that match by canonical name OR by
  // provider_model_id. One round-trip; we partition in JS.
  const ALIAS_COLS =
    `id, provider_id, provider_model_id, weight,
     input_price, cached_input_price, output_price, cache_write_price,
     audio_input_price, audio_output_price`;

  const { data: byCanonical, error: e1 } = await supa
    .from('llm_model_aliases')
    .select(
      `${ALIAS_COLS},
       llm_providers ( id, slug, base_url, auth_type, secret_ref, priority, enabled, config ),
       llm_models!inner ( slug, enabled )`,
    )
    .eq('enabled', true)
    .eq('llm_models.slug', slug);
  if (e1) throw new NoRouteError(`alias canonical lookup failed: ${e1.message}`);

  const { data: byPassthrough, error: e2 } = await supa
    .from('llm_model_aliases')
    .select(
      `${ALIAS_COLS},
       llm_providers ( id, slug, base_url, auth_type, secret_ref, priority, enabled, config )`,
    )
    .eq('enabled', true)
    .eq('provider_model_id', slug);
  if (e2) throw new NoRouteError(`alias passthrough lookup failed: ${e2.message}`);

  // Canonical hits take precedence over passthrough hits — once a slug
  // is registered as a canonical model, "the same string also happens
  // to be a provider_model_id somewhere" should not override the
  // curated routing decision.
  const merged = [...((byCanonical as AliasJoinRow[] | null) ?? [])];
  if (merged.length === 0) {
    merged.push(...((byPassthrough as AliasJoinRow[] | null) ?? []));
  }
  const picked = pickAlias(merged, {
    preferProvider,
    excludeProviders: opts.excludeProviders,
  });

  if (picked && picked.llm_providers) {
    const provider = picked.llm_providers;
    return {
      client: buildClient(env, provider),
      modelToCall: picked.provider_model_id,
      alias: {
        aliasId: picked.id,
        providerId: provider.id,
        providerSlug: provider.slug,
        providerModelId: picked.provider_model_id,
        inputPrice: picked.input_price,
        cachedInputPrice: picked.cached_input_price,
        outputPrice: picked.output_price,
        cacheWritePrice: picked.cache_write_price,
        audioInputPrice: picked.audio_input_price,
        audioOutputPrice: picked.audio_output_price,
      },
      provider: { id: provider.id, slug: provider.slug },
    };
  }

  // Step 3 fallback: OpenRouter passthrough. We pick the row by slug
  // explicitly — relying on it being seeded in 0030 — so that even
  // unregistered models keep flowing while admin curates aliases.
  if (preferProvider && preferProvider !== 'openrouter') {
    throw new NoRouteError(
      `no enabled alias for ${slug} on provider ${preferProvider}`,
    );
  }
  if (opts.excludeProviders?.includes('openrouter')) {
    throw new NoRouteError(
      `no enabled alias for ${slug} and OpenRouter passthrough is excluded`,
    );
  }
  const { data: openrouter, error: e3 } = await supa
    .from('llm_providers')
    .select('id, slug, base_url, auth_type, secret_ref, priority, enabled, config')
    .eq('slug', 'openrouter')
    .eq('enabled', true)
    .maybeSingle();
  if (e3 || !openrouter) {
    throw new NoRouteError(
      `no alias for ${slug} and OpenRouter passthrough provider is not configured`,
    );
  }
  return {
    client: buildClient(env, openrouter),
    modelToCall: slug,
    alias: null,
    provider: { id: openrouter.id, slug: openrouter.slug },
  };
}

// ============================================================
// Audit recording
// ============================================================

export interface AuditUsage {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  // Local heuristic estimates (token-estimate.ts). Optional — callers
  // that don't bother estimating leave them undefined and the audit row
  // stores null. Written to audit_log.est_input_tokens / est_output_tokens
  // so the panel can show a provider-vs-local ratio per row.
  estInputTokens?: number;
  estOutputTokens?: number;
  // Voice call dims. Per-turn deltas pulled from OpenAI Realtime's
  // response.done.usage. text_input/output_tokens for realtime sessions
  // ride along on the existing inputTokens / outputTokens fields.
  audioInputTokens?: number;
  audioOutputTokens?: number;
}

export interface AuditCallOpts extends AuditUsage {
  userId?: string | null;
  conversationId?: string | null;
  taskType: string;
  startedAt: number;
  generationId?: string | null;
  status: 'success' | 'error';
  errorClass?: string | null;
  routeTrace?: unknown;
  tag?: string | null;
  // Per-task free-form metadata (bot_id, scroll_run_id, action, …).
  // Surfaced in audit_log.metadata jsonb so downstream queries can
  // group by these without bloating the column list.
  metadata?: Record<string, unknown> | null;
  /// Worker env, only needed when conversationId points at a group —
  /// recordAudit then dispatches to splitAndDebit instead of single-
  /// user billingDebit. 1v1 callers can omit. (We pass env rather
  /// than a SupabaseClient so the group-billing module can run with
  /// service-role rights regardless of the caller's client kind.)
  env?: Env;
  /// External web search / scrape calls fired during this LLM turn,
  /// captured by WebToolMeter. Each entry lands in audit_web_tool_calls
  /// and sum(costUsd) folds into audit_log.tool_cost_usd + cost_credits
  /// so the single billing_debit covers both LLM and tool spend.
  webTools?: WebToolUsage[];
}

const PER_MILLION = 1_000_000;

// Cost in USD given an alias's per-1M-token prices. Returns null when
// the alias has no pricing rows (e.g. fresh alias added without prices)
// rather than 0 — the panel renders null as '—' which is the honest
// signal that we don't know the cost, vs '0' which would mislead.
export function computeCost(alias: RouteAlias, usage: AuditUsage): number | null {
  let known = false;
  let cost = 0;
  if (alias.inputPrice != null && usage.inputTokens) {
    cost += (usage.inputTokens * alias.inputPrice) / PER_MILLION;
    known = true;
  }
  if (alias.outputPrice != null && usage.outputTokens) {
    cost += (usage.outputTokens * alias.outputPrice) / PER_MILLION;
    known = true;
  }
  if (alias.cachedInputPrice != null && usage.cacheReadTokens) {
    cost += (usage.cacheReadTokens * alias.cachedInputPrice) / PER_MILLION;
    known = true;
  }
  if (alias.cacheWritePrice != null && usage.cacheWriteTokens) {
    cost += (usage.cacheWriteTokens * alias.cacheWritePrice) / PER_MILLION;
    known = true;
  }
  if (alias.audioInputPrice != null && usage.audioInputTokens) {
    cost += (usage.audioInputTokens * alias.audioInputPrice) / PER_MILLION;
    known = true;
  }
  if (alias.audioOutputPrice != null && usage.audioOutputTokens) {
    cost += (usage.audioOutputTokens * alias.audioOutputPrice) / PER_MILLION;
    known = true;
  }
  return known ? cost : null;
}

export async function recordAudit(
  supa: SupabaseClient,
  // null when no alias was ever successfully resolved (every fallback
  // attempt errored out before getting an OK from any provider). The
  // route_trace + status='error' still get persisted; provider_id /
  // model_alias_id / cost_usd just stay null.
  route: ResolvedRoute | null,
  opts: AuditCallOpts,
): Promise<void> {
  const llmCost = route?.alias ? computeCost(route.alias, opts) : null;
  // Web-tool spend (Brave / Tavily / Exa / Serper / Firecrawl) accrues
  // during the same LLM turn. We fold its USD sum into the parent row
  // and apply the same usdToPnd markup so a single billing_debit
  // covers both. Per-call detail goes into audit_web_tool_calls below.
  const toolCalls = opts.webTools ?? [];
  const toolCostUsd = toolCalls.reduce((s, c) => s + (c.costUsd || 0), 0);
  const hasTools = toolCalls.length > 0;
  // Combined USD for billing. usdToPnd treats null/<=0 as 0, so a turn
  // with neither LLM pricing nor any tool cost still settles into the
  // 'skipped' branch below without us special-casing nulls here.
  // Markup is read from billing_config (cached) — ops retunes it from
  // the board without redeploying the worker.
  const combinedUsd = (llmCost ?? 0) + toolCostUsd;
  const markup = await getMarkup(supa);
  const pnd = usdToPnd(combinedUsd, markup);
  const total =
    (opts.inputTokens ?? 0) +
    (opts.outputTokens ?? 0) +
    (opts.cacheReadTokens ?? 0) +
    (opts.cacheWriteTokens ?? 0) +
    (opts.audioInputTokens ?? 0) +
    (opts.audioOutputTokens ?? 0);

  // Billing status preview. The actual billed/unbilled flip happens in
  // billing_debit (when called below); we plant a sensible initial value
  // so audit rows that never debit (no userId, zero PND, error status)
  // settle into a final state on insert.
  //   - 'free'    : no userId at all (system-triggered call w/o owner)
  //   - 'skipped' : has userId but pnd == 0 (error / no usage / no
  //                 alias pricing AND no tool spend)
  //   - 'pending' : will be flipped to billed/unbilled by billing_debit
  const initialBilling: 'free' | 'skipped' | 'pending' = !opts.userId
    ? 'free'
    : pnd <= 0
      ? 'skipped'
      : 'pending';

  // Voice call dims land in dedicated columns so dashboards can split
  // "audio token spend" vs "text token spend" without re-deriving from
  // task_type. Both zero for text-only turns.
  const audioInputTokens = opts.audioInputTokens ?? 0;
  const audioOutputTokens = opts.audioOutputTokens ?? 0;

  const insertRow = {
    user_id: opts.userId ?? null,
    conversation_id: opts.conversationId ?? null,
    task_type: opts.taskType,
    // Use the last-attempted model id when a route was eventually
    // found, otherwise the caller-supplied slug recorded in opts via
    // recordAuditFailure (we expose modelSlug for that path below).
    model_id: route?.modelToCall ?? opts.tag ?? '<unrouted>',
    input_tokens: opts.inputTokens ?? 0,
    output_tokens: opts.outputTokens ?? 0,
    cache_read_tokens: opts.cacheReadTokens ?? 0,
    cache_write_tokens: opts.cacheWriteTokens ?? 0,
    est_input_tokens: opts.estInputTokens ?? null,
    est_output_tokens: opts.estOutputTokens ?? null,
    audio_input_tokens: audioInputTokens,
    audio_output_tokens: audioOutputTokens,
    total_tokens: total,
    // cost_usd stays LLM-only for dashboard continuity. tool_cost_usd
    // breaks out the web-tool spend; cost_credits below is the
    // combined debit (LLM + tools, after markup).
    cost_usd: llmCost,
    tool_cost_usd: hasTools ? toolCostUsd : null,
    cost_credits: pnd,
    billing_status: initialBilling,
    generation_id: opts.generationId ?? null,
    latency_ms: Date.now() - opts.startedAt,
    status: opts.status,
    error_class: opts.errorClass ?? null,
    provider_id: route?.provider.id ?? null,
    model_alias_id: route?.alias?.aliasId ?? null,
    route_trace: (opts.routeTrace as Json | null) ?? null,
    tag: opts.tag ?? null,
    ...(opts.metadata ? { metadata: opts.metadata as Json } : {}),
  };

  const { data: inserted, error } = await supa
    .from('audit_log')
    .insert(insertRow)
    .select('id')
    .single();
  if (error) {
    console.warn('[audit_log insert]', error.message);
    return;
  }

  // Per-call web-tool breakdown. Best-effort: an insert error here
  // leaves the parent row + debit intact but loses the detail row(s)
  // for ops. We log and move on — never propagate to the LLM caller.
  if (hasTools && inserted?.id) {
    const auditId = inserted.id as string;
    const childRows = toolCalls.map((c) => ({
      audit_log_id: auditId,
      provider: c.provider,
      kind: c.kind,
      target: c.target,
      status: c.status,
      error_class: c.errorClass ?? null,
      latency_ms: c.latencyMs,
      result_count: c.resultCount ?? null,
      cost_usd: c.costUsd,
    }));
    const { error: childErr } = await supa
      .from('audit_web_tool_calls')
      .insert(childRows);
    if (childErr) {
      console.warn('[audit_web_tool_calls insert]', childErr.message);
    }
  }

  // Post-insert debit. Errors are swallowed inside billingDebit /
  // splitAndDebit — never propagate billing-side failures back to the
  // LLM caller. The next pre-call gate handles consequences
  // (insufficient balance blocks further requests in 1v1; group
  // members are flagged overdrawn for next-turn exclusion).
  if (initialBilling === 'pending' && inserted?.id) {
    const auditId = inserted.id as string;
    // Branch on conv type: groups split across all participating
    // members, 1v1 / system tasks debit a single user.
    const isGroup = opts.conversationId
      ? await isGroupConversation(supa, opts.conversationId)
      : false;
    if (isGroup && opts.env) {
      await splitAndDebit({ env: opts.env, auditLogId: auditId }).catch((err) =>
        console.warn('[recordAudit] splitAndDebit failed', err),
      );
    } else if (opts.userId) {
      await billingDebit(supa, opts.userId, auditId, pnd);
    }
  }
}

// Cheap conv-type check used by recordAudit. We could push this into
// recordAudit's caller (let them pass `isGroup`) but the conv type
// branch is genuinely the audit layer's concern: 1v1 means a single
// debit, group means a multi-user split, and the right place to
// decide is right where the audit row gets inserted.
async function isGroupConversation(
  supa: SupabaseClient,
  conversationId: string,
): Promise<boolean> {
  const { data } = await supa
    .from('conversations')
    .select('conversation_type')
    .eq('id', conversationId)
    .maybeSingle();
  return data?.conversation_type === 'group';
}

// Convenience: pull token usage from an OpenAI completion.usage object,
// including Anthropic prompt-cache fields when OpenRouter passes them
// through (cached_tokens / cache_creation_input_tokens / etc).
export function usageFromCompletion(
  usage:
    | {
        prompt_tokens?: number | null;
        completion_tokens?: number | null;
        // OpenAI's prompt_tokens_details surfaces cache reads
        prompt_tokens_details?: { cached_tokens?: number | null } | null;
        // OpenRouter / Anthropic-passthrough surface these names for
        // the cache_creation tokens (writes).
        cache_creation_input_tokens?: number | null;
        cache_read_input_tokens?: number | null;
      }
    | null
    | undefined,
): AuditUsage {
  if (!usage) return {};
  const cacheRead =
    usage.cache_read_input_tokens ?? usage.prompt_tokens_details?.cached_tokens ?? 0;
  const cacheWrite = usage.cache_creation_input_tokens ?? 0;
  // promptTokens conventionally includes cached tokens. We split them
  // so accounting is non-overlapping: input = prompt - cache_read.
  const promptTotal = usage.prompt_tokens ?? 0;
  const input = Math.max(0, promptTotal - (cacheRead ?? 0));
  return {
    inputTokens: input,
    outputTokens: usage.completion_tokens ?? 0,
    cacheReadTokens: cacheRead ?? 0,
    cacheWriteTokens: cacheWrite ?? 0,
  };
}

// ============================================================
// Fallback orchestration
// ============================================================
//
// withFallback wraps resolveRoute + a runner closure (the actual
// completion call) in a retry loop. On a transient failure from one
// provider it pushes that provider into excludeProviders and
// re-resolves — picking the next-highest-weight enabled alias for the
// same canonical model — and tries again. On a fatal failure (auth,
// bad request, context length) it stops immediately because retrying
// won't help.
//
// route_trace gets populated as we go so the audit row reflects the
// full chain ("WR 503 → OR 200" or "WR 401 → OR 503 → exhausted").
//
// Streaming callers (bot-reply.ts) and multi-turn agent loops
// (scroll-runner.ts) need different handling — once bytes have started
// flowing to the client, fallback isn't safe. Those keep a single
// resolveRoute() and don't call withFallback yet.

export interface RouteTraceEntry {
  attempt: number;
  provider_slug: string;
  alias_id: string | null;
  status: 'ok' | 'transient_err' | 'fatal_err' | 'no_route';
  error_class?: string;
  error_message?: string;
  latency_ms: number;
}

export interface FallbackOpts extends RouteResolveOpts {
  // Hard cap on total attempts (resolveRoute + runner) before we give
  // up and throw FallbackError. Default 3.
  maxAttempts?: number;
}

export interface FallbackResult<T> {
  result: T;
  route: ResolvedRoute;
  routeTrace: RouteTraceEntry[];
}

export class FallbackError extends Error {
  routeTrace: RouteTraceEntry[];
  lastError: unknown;
  // The route at the moment of the last failed attempt (if any
  // resolveRoute succeeded). null when no provider could even be
  // resolved (NoRouteError on first attempt).
  lastRoute: ResolvedRoute | null;
  constructor(message: string, opts: {
    routeTrace: RouteTraceEntry[];
    lastError: unknown;
    lastRoute: ResolvedRoute | null;
  }) {
    super(message);
    this.name = 'FallbackError';
    this.routeTrace = opts.routeTrace;
    this.lastError = opts.lastError;
    this.lastRoute = opts.lastRoute;
  }
}

// Classify a thrown error into (transient, error_class). Transient =
// "another provider might handle this same request fine" (rate limit,
// timeout, 5xx, network). Fatal = "the request itself is broken,
// retrying anywhere is wasted" (auth, bad input, context length, model
// not found). Unknown shape defaults to transient — bounded by
// maxAttempts so worst case is N retries on weird shapes.
export function classifyError(err: unknown): {
  errorClass: string;
  transient: boolean;
  message: string;
} {
  if (err && typeof err === 'object') {
    const e = err as { status?: number; code?: string; message?: string; name?: string };
    const message = e.message ?? String(err);
    const lower = message.toLowerCase();
    const status = typeof e.status === 'number' ? e.status : undefined;

    if (status === 401 || status === 403) return { errorClass: 'auth', transient: false, message };
    if (status === 404) return { errorClass: 'not_found', transient: false, message };
    if (status === 400) {
      // 400 is usually fatal except when it's the gateway saying "this
      // model is overloaded right now" — but we can't reliably detect
      // that from the message; treat as fatal.
      if (lower.includes('context length') || lower.includes('context_length') || lower.includes('maximum context')) {
        return { errorClass: 'context_length', transient: false, message };
      }
      return { errorClass: 'bad_request', transient: false, message };
    }
    if (status === 408 || status === 504) return { errorClass: 'timeout', transient: true, message };
    if (status === 429) return { errorClass: 'rate_limit', transient: true, message };
    if (status === 502 || status === 503) return { errorClass: 'provider_unavailable', transient: true, message };
    if (typeof status === 'number' && status >= 500) return { errorClass: 'server_error', transient: true, message };

    if (lower.includes('econnreset') || lower.includes('econnrefused') || lower.includes('etimedout') || lower.includes('fetch failed')) {
      return { errorClass: 'network', transient: true, message };
    }
    if (e.name === 'NoRouteError') return { errorClass: 'no_route', transient: false, message };
    if (lower.includes('safety') || lower.includes('refus')) {
      return { errorClass: 'safety_refusal', transient: false, message };
    }
  }
  // Unknown — assume transient. maxAttempts caps the blast radius.
  return { errorClass: 'unknown', transient: true, message: String(err) };
}

export async function withFallback<T>(
  supa: SupabaseClient,
  env: Env,
  opts: FallbackOpts,
  runner: (route: ResolvedRoute) => Promise<T>,
): Promise<FallbackResult<T>> {
  const maxAttempts = opts.maxAttempts ?? 3;
  const tried: string[] = [...(opts.excludeProviders ?? [])];
  const routeTrace: RouteTraceEntry[] = [];
  let lastError: unknown = null;
  let lastRoute: ResolvedRoute | null = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const attemptStart = Date.now();
    let route: ResolvedRoute;
    try {
      route = await resolveRoute(supa, env, { ...opts, excludeProviders: tried });
    } catch (err) {
      const cls = classifyError(err);
      routeTrace.push({
        attempt,
        provider_slug: '(no-route)',
        alias_id: null,
        status: 'no_route',
        error_class: cls.errorClass,
        error_message: cls.message.slice(0, 200),
        latency_ms: Date.now() - attemptStart,
      });
      lastError = err;
      // No provider available means subsequent loops can't help either.
      break;
    }
    lastRoute = route;

    try {
      const result = await runner(route);
      routeTrace.push({
        attempt,
        provider_slug: route.provider.slug,
        alias_id: route.alias?.aliasId ?? null,
        status: 'ok',
        latency_ms: Date.now() - attemptStart,
      });
      return { result, route, routeTrace };
    } catch (err) {
      const cls = classifyError(err);
      routeTrace.push({
        attempt,
        provider_slug: route.provider.slug,
        alias_id: route.alias?.aliasId ?? null,
        status: cls.transient ? 'transient_err' : 'fatal_err',
        error_class: cls.errorClass,
        error_message: cls.message.slice(0, 200),
        latency_ms: Date.now() - attemptStart,
      });
      lastError = err;
      if (!cls.transient) break;
      tried.push(route.provider.slug);
    }
  }

  throw new FallbackError(
    `withFallback exhausted (${routeTrace.length} attempt${routeTrace.length === 1 ? '' : 's'})`,
    { routeTrace, lastError, lastRoute },
  );
}
