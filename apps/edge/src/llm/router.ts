import OpenAI from 'openai';
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import { serviceClient } from '../lib/supabase';
import type { Json } from '../db/schema';
import { billingDebit, getMarkup, usdToPnd } from '../lib/billing';
import { putCachedBalance } from '../lib/balance-cache';
import { splitAndDebit } from '../lib/group-billing';
import type { WebToolUsage } from '../lib/web-meter';
import { uuidv7 } from '../lib/ids';
import { kvConfig } from '../lib/kv-config';
import { fetchGatewayCost, GATEWAY_COST_PENDING } from '../lib/ai-gateway';
import type { AuditMessage } from '../queue/audit-types';
import {
  usageFromCompletion,
  type ProviderUsageDetails,
} from './provider-usage';

export { usageFromCompletion } from './provider-usage';

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
// Auth is BYOK-on-gateway: provider API keys live in the AI Gateway
// dashboard, never in worker env. Every LLM request carries the
// cf-aig-authorization header (env.CF_AIG_RUN_TOKEN) to authenticate
// to the gateway itself; the gateway then injects the stored upstream
// provider key. No per-provider secret_ref — adding a provider in the
// admin UI just needs its key stored in the gateway dashboard.

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
  // Caller context tagged onto each LLM request as the cf-aig-metadata
  // header, so the AI Gateway dashboard / logs are sliceable by user and
  // conversation. task_type is always tagged from `taskType` above.
  // turnId stamps every LLM call of one logical turn with a shared id so
  // persistAuditMessage can sum that turn's cost from the gateway logs;
  // pass the same value as AuditCallOpts.auditId.
  metadata?: {
    userId?: string | null;
    conversationId?: string | null;
    turnId?: string | null;
  };
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

// Which OpenAI-dialect API a provider speaks. 'chat' = the universal
// Chat Completions endpoint every provider supports (OpenRouter etc.).
// 'responses' = OpenAI's native Responses API — only the OpenAI-native
// provider (CF AI Gateway → OpenAI passthrough) handles it. Sourced from
// llm_providers.config.api; absent/anything-else defaults to 'chat'.
export type ProviderApiStyle = 'chat' | 'responses';

export function providerApiStyle(config: unknown): ProviderApiStyle {
  if (config && typeof config === 'object' && !Array.isArray(config)) {
    if ((config as Record<string, unknown>).api === 'responses') return 'responses';
  }
  return 'chat';
}

export interface ResolvedRoute {
  client: OpenAI;
  // The provider-specific id to put in completions.create({ model }).
  // For canonical/aliased routes this is alias.providerModelId; for the
  // OpenRouter passthrough fallback it's the raw slug the caller passed.
  modelToCall: string;
  alias: RouteAlias | null;
  provider: { id: string; slug: string; apiStyle: ProviderApiStyle };
}

export class NoRouteError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NoRouteError';
  }
}

// Internal: shape of the alias join result from supabase-js. Exported
// only so the pickAlias unit test can construct rows without going
// through the DB.
export type AliasJoinRow = {
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
        priority: number;
        enabled: boolean;
        config: unknown;
      }
    | null;
};

// Blended USD-per-1M-token reference price for the iOS model picker's
// relative-cost display. Weighted 7:2:1 over (cache_hit, input, output),
// reflecting the observed token mix on chat traffic where most input is
// replay against a cached prefix and output is the smallest slice. When
// an alias has no cached_input_price set, cache_hit falls back to
// input_price (no discount applied). Returns null when either input or
// output is missing. Not used for routing — see pickAlias.
const BLEND_WEIGHT_CACHE_HIT = 0.7;
const BLEND_WEIGHT_INPUT = 0.2;
const BLEND_WEIGHT_OUTPUT = 0.1;

export interface BlendablePrices {
  inputPrice: number | null;
  cachedInputPrice: number | null;
  outputPrice: number | null;
}

export function blendedUsdPerMillion(p: BlendablePrices): number | null {
  if (p.inputPrice == null || p.outputPrice == null) return null;
  const cacheHit = p.cachedInputPrice ?? p.inputPrice;
  return (
    BLEND_WEIGHT_CACHE_HIT * cacheHit +
    BLEND_WEIGHT_INPUT * p.inputPrice +
    BLEND_WEIGHT_OUTPUT * p.outputPrice
  );
}

export function pickAlias(
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
  // Ordering: weight DESC (admin's manual preference) → provider.priority
  // ASC (registry tiebreaker) → alias id (stable output). weight=0 marks
  // an alias as standby — kept out of the live pool unless it's all
  // that's left after filtering.
  //
  // Cost-based "cheapest provider wins" routing is intentionally NOT done
  // here anymore — per-cost / conditional routing belongs on the AI
  // Gateway (Dynamic Routing), configured in the dashboard.
  const live = candidates.filter((r) => r.weight > 0);
  const pool = live.length > 0 ? live : candidates;
  pool.sort((a, b) => {
    if (b.weight !== a.weight) return b.weight - a.weight;
    const pa = a.llm_providers!.priority;
    const pb = b.llm_providers!.priority;
    if (pa !== pb) return pa - pb;
    return a.id.localeCompare(b.id);
  });
  return pool[0]!;
}

function buildClient(
  env: Env,
  provider: { base_url: string; config: unknown },
  aigMetadata?: Record<string, string>,
): OpenAI {
  const token = env.CF_AIG_RUN_TOKEN;
  if (!token) {
    throw new NoRouteError(
      'CF_AIG_RUN_TOKEN is not bound on the worker — set the AI Gateway ' +
        'run token secret (gateway Settings → Authenticated Gateway)',
    );
  }
  const cfg =
    provider.config && typeof provider.config === 'object' && !Array.isArray(provider.config)
      ? (provider.config as Record<string, unknown>)
      : {};
  const extraHeaders =
    (cfg.extra_headers as Record<string, string> | undefined) ?? {};
  return new OpenAI({
    // BYOK-on-gateway: the real upstream key is stored in the AI Gateway
    // dashboard and injected by the gateway. The OpenAI SDK constructor
    // requires a non-empty apiKey, so this placeholder just satisfies it
    // — the provider Authorization header is deleted below (null) so the
    // gateway's stored BYOK key is what reaches the upstream.
    apiKey: 'cf-aig-byok',
    baseURL: provider.base_url,
    defaultHeaders: {
      'HTTP-Referer': 'https://pendingname.com',
      'X-Title': 'PendingBot',
      // Authenticate to the gateway itself; it injects the BYOK key.
      'cf-aig-authorization': `Bearer ${token}`,
      // Drop the SDK's Authorization header — BYOK requires no upstream
      // provider auth header on the request.
      Authorization: null,
      // cf-aig-metadata rides on every request the AI Gateway proxies,
      // tagging the gateway log so it's sliceable by task / user / conv.
      ...(aigMetadata ? { 'cf-aig-metadata': JSON.stringify(aigMetadata) } : {}),
      ...extraHeaders,
    },
  });
}

// Assemble the cf-aig-metadata payload from the route opts. AI Gateway
// caps custom metadata at 5 entries; we send at most 3.
function aigMetadataFrom(opts: RouteResolveOpts): Record<string, string> | undefined {
  const m: Record<string, string> = {};
  if (opts.taskType) m.task_type = opts.taskType;
  if (opts.metadata?.userId) m.user_id = opts.metadata.userId;
  if (opts.metadata?.conversationId) m.conversation_id = opts.metadata.conversationId;
  if (opts.metadata?.turnId) m.turn_id = opts.metadata.turnId;
  return Object.keys(m).length > 0 ? m : undefined;
}

// ─────────────────────────────────────────────────────────────────────
// Isolate-local caches for admin-curated routing config. All three
// tables (task_routing_rules / llm_model_aliases / llm_providers) are
// edited from the board admin roughly never and read on every LLM
// dispatch — a small TTL keeps them hot on the worker isolate without
// putting Supabase RTTs on the first-token path.
//
// 5 min was picked to match getMarkup + getThreshold patterns. An admin
// price edit propagates within ~TTL across all isolates.
// ─────────────────────────────────────────────────────────────────────
const ROUTE_CACHE_TTL_MS = 5 * 60_000;
const ROUTE_CACHE_TTL_S = ROUTE_CACHE_TTL_MS / 1000;

interface CachedRule {
  overrideSlug: string | null;
  preferProvider: string | null;
}
const taskRuleCache = new Map<string, { at: number; value: CachedRule | null }>();

interface CachedAliasSet {
  byCanonical: AliasJoinRow[];
  byPassthrough: AliasJoinRow[];
}
const aliasCache = new Map<string, { at: number; value: CachedAliasSet }>();

interface CachedProvider {
  id: string;
  slug: string;
  base_url: string;
  priority: number;
  enabled: boolean;
  config: unknown;
}
const providerCache = new Map<string, { at: number; value: CachedProvider | null }>();

/** For tests / forced refresh after an admin edit on the same isolate. */
export function _resetRouteCaches(): void {
  taskRuleCache.clear();
  aliasCache.clear();
  providerCache.clear();
}

async function getTaskRule(
  supa: SupabaseClient,
  env: Env,
  taskType: string,
): Promise<CachedRule | null> {
  const now = Date.now();
  const hit = taskRuleCache.get(taskType);
  if (hit && now - hit.at < ROUTE_CACHE_TTL_MS) return hit.value;
  const value = await kvConfig(
    env,
    `cfg:route-rule:${taskType}`,
    ROUTE_CACHE_TTL_S,
    async (): Promise<CachedRule | null> => {
      const { data: rule } = await supa
        .from('task_routing_rules')
        .select(
          `match_priority, override_model_id, prefer_provider_id,
           override_model:llm_models!task_routing_rules_override_model_fkey ( slug ),
           prefer_provider:llm_providers!task_routing_rules_prefer_provider_fkey ( slug )`,
        )
        .eq('task_type', taskType)
        .eq('enabled', true)
        .order('match_priority', { ascending: true })
        .limit(1)
        .maybeSingle();
      return rule
        ? {
            overrideSlug: (rule.override_model as { slug?: string } | null)?.slug ?? null,
            preferProvider: (rule.prefer_provider as { slug?: string } | null)?.slug ?? null,
          }
        : null;
    },
  );
  taskRuleCache.set(taskType, { at: now, value });
  return value;
}

async function getAliasSet(
  supa: SupabaseClient,
  env: Env,
  slug: string,
): Promise<CachedAliasSet> {
  const now = Date.now();
  const hit = aliasCache.get(slug);
  if (hit && now - hit.at < ROUTE_CACHE_TTL_MS) return hit.value;
  const value = await kvConfig(
    env,
    `cfg:route-alias:${slug}`,
    ROUTE_CACHE_TTL_S,
    async (): Promise<CachedAliasSet> => {
      const ALIAS_COLS =
        `id, provider_id, provider_model_id, weight,
         input_price, cached_input_price, output_price, cache_write_price,
         audio_input_price, audio_output_price`;
      const [{ data: byCanonical, error: e1 }, { data: byPassthrough, error: e2 }] =
        await Promise.all([
          supa
            .from('llm_model_aliases')
            .select(
              `${ALIAS_COLS},
               llm_providers ( id, slug, base_url, priority, enabled, config ),
               llm_models!inner ( slug, enabled )`,
            )
            .eq('enabled', true)
            .eq('llm_models.slug', slug),
          supa
            .from('llm_model_aliases')
            .select(
              `${ALIAS_COLS},
               llm_providers ( id, slug, base_url, priority, enabled, config )`,
            )
            .eq('enabled', true)
            .eq('provider_model_id', slug),
        ]);
      if (e1) throw new NoRouteError(`alias canonical lookup failed: ${e1.message}`);
      if (e2) throw new NoRouteError(`alias passthrough lookup failed: ${e2.message}`);
      return {
        byCanonical: (byCanonical as AliasJoinRow[] | null) ?? [],
        byPassthrough: (byPassthrough as AliasJoinRow[] | null) ?? [],
      };
    },
  );
  aliasCache.set(slug, { at: now, value });
  return value;
}

async function getProvider(
  supa: SupabaseClient,
  env: Env,
  slug: string,
): Promise<CachedProvider | null> {
  const now = Date.now();
  const hit = providerCache.get(slug);
  if (hit && now - hit.at < ROUTE_CACHE_TTL_MS) return hit.value;
  const value = await kvConfig(
    env,
    `cfg:route-provider:${slug}`,
    ROUTE_CACHE_TTL_S,
    async (): Promise<CachedProvider | null> => {
      const { data } = await supa
        .from('llm_providers')
        .select('id, slug, base_url, priority, enabled, config')
        .eq('slug', slug)
        .eq('enabled', true)
        .maybeSingle();
      return (data as CachedProvider | null) ?? null;
    },
  );
  providerCache.set(slug, { at: now, value });
  return value;
}

export async function resolveRoute(
  supa: SupabaseClient,
  env: Env,
  opts: RouteResolveOpts,
): Promise<ResolvedRoute> {
  let slug = opts.modelSlug.trim();
  if (!slug) throw new NoRouteError('empty model slug');
  let preferProvider = opts.preferProvider;

  // Per-task override pass. Lowest-priority enabled rule wins; caller-
  // supplied preferProvider overrides the rule's. Cached on the worker
  // isolate per task_type for 5 min.
  if (opts.taskType) {
    const rule = await getTaskRule(supa, env, opts.taskType);
    if (rule) {
      if (rule.overrideSlug) slug = rule.overrideSlug;
      if (!preferProvider && rule.preferProvider) preferProvider = rule.preferProvider;
    }
  }

  // Pull all aliases that match by canonical slug OR by passthrough
  // provider_model_id, then partition in JS. Cached per slug.
  const { byCanonical, byPassthrough } = await getAliasSet(supa, env, slug);

  // Canonical hits take precedence over passthrough hits — once a slug
  // is registered as a canonical model, "the same string also happens
  // to be a provider_model_id somewhere" should not override the
  // curated routing decision.
  const merged = [...byCanonical];
  if (merged.length === 0) {
    merged.push(...byPassthrough);
  }
  const picked = pickAlias(merged, {
    preferProvider,
    excludeProviders: opts.excludeProviders,
  });

  if (picked && picked.llm_providers) {
    const provider = picked.llm_providers;
    return {
      client: buildClient(env, provider, aigMetadataFrom(opts)),
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
      provider: {
        id: provider.id,
        slug: provider.slug,
        apiStyle: providerApiStyle(provider.config),
      },
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
  const openrouter = await getProvider(supa, env, 'openrouter');
  if (!openrouter) {
    throw new NoRouteError(
      `no alias for ${slug} and OpenRouter passthrough provider is not configured`,
    );
  }
  return {
    client: buildClient(env, openrouter, aigMetadataFrom(opts)),
    modelToCall: slug,
    alias: null,
    provider: {
      id: openrouter.id,
      slug: openrouter.slug,
      apiStyle: providerApiStyle(openrouter.config),
    },
  };
}

// ============================================================
// Audit recording
// ============================================================

export interface AuditUsage extends ProviderUsageDetails {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
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
  // The turn id — generated by the caller, stamped into cf-aig-metadata
  // (RouteResolveOpts.metadata.turnId) AND reused here as the audit_log
  // row id, so persistAuditMessage can match this turn's gateway logs.
  // Omitted → buildAuditMessage generates a fresh uuidv7 (the gateway
  // cost lookup then can't correlate, so it settles with no LLM cost).
  auditId?: string;
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
  /// External web search / scrape calls fired during this LLM turn,
  /// captured by WebToolMeter. Each entry lands in audit_web_tool_calls
  /// and sum(costUsd) folds into audit_log.tool_cost_usd + cost_credits
  /// so the single billing_debit covers both LLM and tool spend.
  webTools?: WebToolUsage[];
}

const PER_MILLION = 1_000_000;

// Local price-book cost — used ONLY for voice calls. OpenAI Realtime is
// a direct iOS↔OpenAI WebRTC session: it never flows through the worker
// or the AI Gateway, so there is no gateway log and no provider-reported
// cost to read. Its cost is computed here from the alias audio prices ×
// the audio token counts iOS reports. Every other task type goes
// through the gateway and bills on providerCostUsd / the gateway log
// (see persistAuditMessage) — no local computation.
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

// ─────────────────────────────────────────────────────────────────────
// Audit is offloaded onto AUDIT_QUEUE: the LLM response path calls
// enqueueAudit (fast — one queue send), and the worker's own `queue`
// handler (src/index.ts) calls persistAuditMessage to do the audit_log
// insert + child rows + billing debit off the response path.
//
// enqueueAudit returns the audit_log id synchronously because it's
// generated up-front (uuidv7) — callers that need the id don't wait on
// the DB, and the same id is the consumer's idempotency key.
// ─────────────────────────────────────────────────────────────────────

// Produce the serializable queue message. Latency is measured here, at
// enqueue time — the consumer runs later and can't derive it.
function buildAuditMessage(
  route: ResolvedRoute | null,
  opts: AuditCallOpts,
): AuditMessage {
  return {
    // Reuse the caller's turn id when given — it's the same value
    // stamped into cf-aig-metadata, which is how persistAuditMessage
    // correlates this row with the gateway's cost logs.
    auditId: opts.auditId ?? uuidv7(),
    latencyMs: Date.now() - opts.startedAt,
    route: route
      ? { modelToCall: route.modelToCall, alias: route.alias, provider: route.provider }
      : null,
    opts,
  };
}

// Enqueue audit + billing for this LLM turn. Returns the audit_log id
// (pre-generated) so callers can reference the row without awaiting the
// insert. Never throws — a queue-send failure falls back to an inline
// persist so an audit/debit is never silently dropped.
export async function enqueueAudit(
  env: Env,
  // null when no alias was ever successfully resolved (every fallback
  // attempt errored out before getting an OK from any provider). The
  // route_trace + status='error' still get persisted; provider_id /
  // model_alias_id / cost_usd just stay null.
  route: ResolvedRoute | null,
  opts: AuditCallOpts,
): Promise<string> {
  const msg = buildAuditMessage(route, opts);
  try {
    await env.AUDIT_QUEUE.send(msg);
  } catch (err) {
    // Queue unavailable — persist inline rather than lose the row. The
    // inline persist must not throw back to the LLM caller either.
    console.warn('[enqueueAudit] queue send failed, persisting inline', err);
    try {
      await persistAuditMessage(env, msg);
    } catch (err2) {
      console.error('[enqueueAudit] inline persist also failed', err2);
    }
  }
  return msg.auditId;
}

// Thrown by persistAuditMessage when a turn's AI Gateway cost log is
// not queryable yet (ingestion lag). The queue consumer re-queues the
// message with a delay on this — distinct from a transient DB failure.
export class GatewayCostPendingError extends Error {
  constructor(auditId: string) {
    super(`AI Gateway cost not yet available for turn ${auditId}`);
    this.name = 'GatewayCostPendingError';
  }
}

// Consumer side: do the actual audit_log insert + child rows + billing.
// Idempotent on msg.auditId — at-least-once delivery means this can run
// twice for the same message, so the audit_log insert is an
// upsert/ignoreDuplicates and a duplicate delivery returns early before
// re-running billing.
//
// Throws on a transient audit_log insert failure (or GatewayCostPendingError)
// so the queue retries; child-row inserts and billing are best-effort
// (logged, never thrown) exactly as the old inline recordAudit treated them.
export async function persistAuditMessage(
  env: Env,
  msg: AuditMessage,
): Promise<void> {
  const supa = serviceClient(env);
  const { auditId, latencyMs, route, opts } = msg;
  // Billing cost:
  //   1. providerCostUsd — the upstream's own reported figure
  //      (OpenRouter), summed across the turn by mergeProviderUsageDetails.
  //   2. voice_call — local audio-price computation; OpenAI Realtime is
  //      direct iOS↔OpenAI WebRTC, never gateway-proxied, so there is no
  //      gateway log to read.
  //   3. otherwise — the AI Gateway's computed cost, read from its Logs
  //      API by turn id (auditId is the value stamped into cf-aig-metadata).
  let llmCost = opts.providerCostUsd ?? null;
  if (llmCost == null && opts.taskType === 'voice_call') {
    llmCost = route?.alias ? computeCost(route.alias, opts) : null;
  } else if (
    llmCost == null &&
    opts.status === 'success' &&
    (opts.userId != null || opts.conversationId != null)
  ) {
    const gw = await fetchGatewayCost(env, auditId);
    if (gw === GATEWAY_COST_PENDING) {
      // The turn's gateway log hasn't been ingested yet. Throw BEFORE
      // any insert so the queue consumer re-queues with a delay — the
      // idempotent upsert below would otherwise lock in a null cost
      // that a later retry can't correct.
      throw new GatewayCostPendingError(auditId);
    }
    llmCost = gw;
  }
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

  const isGroupTarget = opts.conversationId
    ? await isGroupConversation(supa, opts.conversationId)
    : false;

  // Billing status preview. The actual billed/unbilled flip happens in
  // billing_debit (when called below); we plant a sensible initial value
  // so audit rows that never debit (no userId, zero PND, error status)
  // settle into a final state on insert.
  //   - 'free'    : no billable owner/group target at all
  //   - 'skipped' : has billable target but pnd == 0 (error / no usage / no
  //                 alias pricing AND no tool spend)
  //   - 'pending' : will be flipped to billed/unbilled by billing_debit
  const initialBilling: 'free' | 'skipped' | 'pending' = !opts.userId && !isGroupTarget
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
    // Producer-generated uuidv7. Explicit (not DB-defaulted) so it
    // doubles as the consumer's idempotency key below.
    id: auditId,
    user_id: opts.userId ?? null,
    conversation_id: opts.conversationId ?? null,
    task_type: opts.taskType,
    // Use the last-attempted model id when a route was eventually
    // found, otherwise the caller-supplied tag.
    model_id: route?.modelToCall ?? opts.tag ?? '<unrouted>',
    input_tokens: opts.inputTokens ?? 0,
    output_tokens: opts.outputTokens ?? 0,
    cache_read_tokens: opts.cacheReadTokens ?? 0,
    cache_write_tokens: opts.cacheWriteTokens ?? 0,
    audio_input_tokens: audioInputTokens,
    audio_output_tokens: audioOutputTokens,
    total_tokens: total,
    // cost_usd is the LLM cost that drives billing — the provider-reported
    // figure for this turn. tool_cost_usd breaks out web-tool spend;
    // cost_credits below is the combined debit (LLM + tools, after markup).
    cost_usd: llmCost,
    tool_cost_usd: hasTools ? toolCostUsd : null,
    cost_credits: pnd,
    billing_status: initialBilling,
    generation_id: opts.generationId ?? null,
    latency_ms: latencyMs,
    status: opts.status,
    error_class: opts.errorClass ?? null,
    provider_id: route?.provider.id ?? null,
    model_alias_id: route?.alias?.aliasId ?? null,
    route_trace: (opts.routeTrace as Json | null) ?? null,
    tag: opts.tag ?? null,
    ...(opts.metadata ? { metadata: opts.metadata as Json } : {}),
  };

  // Upsert (not plain insert) so a duplicate queue delivery — the
  // consumer can run any message more than once — is a no-op rather
  // than a primary-key error. ignoreDuplicates means a conflicting row
  // is left untouched and NOT returned, so an empty result set is the
  // signal "already persisted on an earlier delivery".
  const { data: insertedRows, error } = await supa
    .from('audit_log')
    .upsert(insertRow, { onConflict: 'id', ignoreDuplicates: true })
    .select('id');
  if (error) {
    // Transient — throw so the queue retries this message.
    console.warn('[audit_log upsert]', error.message);
    throw new Error(`audit_log upsert failed: ${error.message}`);
  }
  if (!insertedRows || insertedRows.length === 0) {
    // Duplicate delivery — the row (and its children + debit) already
    // landed on an earlier attempt. Nothing more to do.
    return;
  }

  // Per-call web-tool breakdown. Best-effort: an insert error here
  // leaves the parent row + debit intact but loses the detail row(s)
  // for ops. We log and move on — never propagate / never retry.
  if (hasTools) {
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
  // splitAndDebit — never propagate billing-side failures. The next
  // pre-call gate handles consequences (insufficient balance blocks
  // further requests in 1v1; group members are flagged overdrawn for
  // next-turn exclusion). Runs only on the fresh-insert path above, so
  // a duplicate delivery never double-debits.
  if (initialBilling === 'pending') {
    // Branch on conv type: groups split across all participating
    // members, 1v1 / system tasks debit a single user.
    if (isGroupTarget) {
      await splitAndDebit({ env, auditLogId: auditId }).catch((err) =>
        console.warn('[persistAuditMessage] splitAndDebit failed', err),
      );
    } else if (opts.userId) {
      const newBalance = await billingDebit(supa, opts.userId, auditId, pnd);
      // Keep the per-user KV balance cache in sync so the next
      // requireBalance call skips Supabase. RPC returned null = swallowed
      // error; leave the cache alone so the next miss re-reads.
      if (newBalance != null) {
        await putCachedBalance(env, opts.userId, newBalance).catch(() => undefined);
      }
    }
  }
}

// Cheap conv-type check used by persistAuditMessage. We could push this
// into the caller (let them pass `isGroup`) but the conv type
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
// (envelope-runner.ts) need different handling — once bytes have started
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
