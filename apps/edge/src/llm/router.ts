import OpenAI from 'openai';
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';

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
  const { data: byCanonical, error: e1 } = await supa
    .from('llm_model_aliases')
    .select(
      `id, provider_id, provider_model_id, weight, input_price, cached_input_price, output_price, cache_write_price,
       llm_providers ( id, slug, base_url, auth_type, secret_ref, priority, enabled, config ),
       llm_models!inner ( slug, enabled )`,
    )
    .eq('enabled', true)
    .eq('llm_models.slug', slug);
  if (e1) throw new NoRouteError(`alias canonical lookup failed: ${e1.message}`);

  const { data: byPassthrough, error: e2 } = await supa
    .from('llm_model_aliases')
    .select(
      `id, provider_id, provider_model_id, weight, input_price, cached_input_price, output_price, cache_write_price,
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
  return known ? cost : null;
}

export async function recordAudit(
  supa: SupabaseClient,
  route: ResolvedRoute,
  opts: AuditCallOpts,
): Promise<void> {
  const cost = route.alias ? computeCost(route.alias, opts) : null;
  const total =
    (opts.inputTokens ?? 0) +
    (opts.outputTokens ?? 0) +
    (opts.cacheReadTokens ?? 0) +
    (opts.cacheWriteTokens ?? 0);

  const { error } = await supa.from('audit_log').insert({
    user_id: opts.userId ?? null,
    conversation_id: opts.conversationId ?? null,
    task_type: opts.taskType,
    model_id: route.modelToCall,
    input_tokens: opts.inputTokens ?? 0,
    output_tokens: opts.outputTokens ?? 0,
    cache_read_tokens: opts.cacheReadTokens ?? 0,
    cache_write_tokens: opts.cacheWriteTokens ?? 0,
    total_tokens: total,
    cost_usd: cost,
    generation_id: opts.generationId ?? null,
    latency_ms: Date.now() - opts.startedAt,
    status: opts.status,
    error_class: opts.errorClass ?? null,
    provider_id: route.provider.id,
    model_alias_id: route.alias?.aliasId ?? null,
    route_trace: (opts.routeTrace as never) ?? null,
    tag: opts.tag ?? null,
    ...(opts.metadata ? { metadata: opts.metadata as never } : {}),
  });
  if (error) {
    console.warn('[audit_log insert]', error.message);
  }
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
