import OpenAI from 'openai';
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import { serviceClient } from '../lib/supabase';
import type { Json } from '../db/schema';
import { wallet } from '../billing/wallet-client';
import { usdToPncMicros } from '../billing/pnc';
import { resolveBillingSubjectId } from '../billing/usage-gate';
import { settleGroupSpend } from '../billing/group-wallet';
import type { WebToolUsage } from '../lib/web-meter';
import { uuidv7 } from '../lib/ids';
import { fetchGatewayCost, GATEWAY_COST_PENDING } from '../lib/ai-gateway';
import { traceGeneration } from '../lib/llm-trace';
import type { AuditMessage } from '../queue/audit-types';
import {
  gatewayBaseUrl,
  providerApiStyle,
  resolveProviderSlug,
  REALTIME_PRICING,
  type ProviderApiStyle,
  type ProviderSlug,
} from './providers';
import {
  usageFromCompletion,
  type ProviderUsageDetails,
} from './provider-usage';

export { usageFromCompletion } from './provider-usage';
export type { ProviderApiStyle, ProviderSlug } from './providers';

// LLM router — pure passthrough. A caller-supplied model slug is sent to
// the upstream as-is; the only routing decision is which provider path on
// the Cloudflare AI Gateway it goes through. `openai` → the native
// Responses API; everything else → the OpenRouter passthrough (Chat
// Completions). The provider is picked from the caller's preferProvider
// hint (sourced from bots.model_provider) — see resolveProviderSlug.
//
// Auth is Unified Billing: every LLM request carries only the
// cf-aig-authorization header (env.CF_AIG_RUN_TOKEN) to authenticate to
// the gateway, and no provider key — the gateway pays the upstream from
// the account's AI Gateway credits. No provider API key lives in worker
// env or in the gateway dashboard for openai/anthropic. The lone
// exception is google-ai-studio: Gemini 3.x isn't on the Unified Billing
// native passthrough, so it rides a stored BYOK key selected via the
// cf-aig-byok-alias header (see byokAlias below + gemini-adapter.ts).
//
// NB: a stale BYOK provider key left in the gateway dashboard for a
// Unified-Billing provider hijacks that provider onto the BYOK path and
// fails with "Configured BYOK credentials are unavailable" once its
// secret is gone — the gateway prefers a configured BYOK key over
// credits and won't fall back. Keep the dashboard's Provider Keys empty
// except for the Gemini alias.

export interface RouteResolveOpts {
  modelSlug: string;
  // task_type recorded in audit_log and tagged onto the gateway log.
  taskType?: string;
  // Provider hint — bots.model_provider or a manual pin. 'openai' selects
  // the native Responses route; null / 'openrouter' / anything else uses
  // the OpenRouter passthrough.
  preferProvider?: string;
  // Used by fallback retries: a provider in this list is treated as
  // unavailable, so resolveRoute throws NoRouteError for it.
  excludeProviders?: string[];
  // Caller context tagged onto each LLM request as the cf-aig-metadata
  // header so the AI Gateway logs are sliceable by user / conversation.
  // turnId stamps every LLM call of one logical turn with a shared id so
  // persistAuditMessage can sum that turn's cost from the gateway logs;
  // pass the same value as AuditCallOpts.auditId.
  metadata?: {
    userId?: string | null;
    conversationId?: string | null;
    turnId?: string | null;
  };
}

export interface ResolvedRoute {
  client: OpenAI;
  // The upstream model id to put in completions.create({ model }) — or, for
  // native-adapter providers, the bare provider model id (e.g.
  // `claude-sonnet-4-6`, `gemini-2.5-flash`). Always the caller-supplied
  // slug verbatim (passthrough router does no rewriting).
  modelToCall: string;
  provider: { slug: ProviderSlug; apiStyle: ProviderApiStyle };
  // AI Gateway coordinates for native-adapter providers (anthropic /
  // gemini) that bypass the OpenAI SDK and POST raw to the gateway. The
  // OpenAI-SDK paths (chat / responses) ignore these and use `client`.
  //   baseURL  — gateway base for this provider (no trailing slash), e.g.
  //              https://gateway.ai.cloudflare.com/v1/{acct}/{gw}/anthropic
  //   aigToken — cf-aig-authorization bearer (CF_AIG_RUN_TOKEN)
  baseURL: string;
  aigToken: string;
  // BYOK key alias (cf-aig-byok-alias header) for providers that ride a
  // stored provider key instead of Unified Billing. Set only for
  // google-ai-studio (Gemini 3.x isn't on the UB native passthrough); the
  // gemini adapter sends it. undefined for every other provider.
  byokAlias?: string;
}

export class NoRouteError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NoRouteError';
  }
}

function buildClient(
  env: Env,
  baseURL: string,
  aigMetadata?: Record<string, string>,
): OpenAI {
  const token = env.CF_AIG_RUN_TOKEN;
  if (!token) {
    throw new NoRouteError(
      'CF_AIG_RUN_TOKEN is not bound on the worker — set the AI Gateway ' +
        'run token secret (gateway Settings → Authenticated Gateway)',
    );
  }
  return new OpenAI({
    // Unified Billing: no provider key reaches the upstream. The OpenAI
    // SDK constructor requires a non-empty apiKey, so this placeholder
    // just satisfies it — the provider Authorization header is deleted
    // below (null), so the gateway authenticates via cf-aig-authorization
    // alone and bills the request to the account's AI Gateway credits.
    apiKey: 'unused-unified-billing',
    baseURL,
    defaultHeaders: {
      'HTTP-Referer': 'https://pendingname.com',
      'X-Title': 'PendingBot',
      // Authenticate to the gateway itself; it pays the upstream.
      'cf-aig-authorization': `Bearer ${token}`,
      // Drop the SDK's Authorization header — Unified Billing carries no
      // upstream provider auth header on the request.
      Authorization: null,
      // cf-aig-metadata rides on every request the AI Gateway proxies,
      // tagging the gateway log so it's sliceable by task / user / conv.
      ...(aigMetadata ? { 'cf-aig-metadata': JSON.stringify(aigMetadata) } : {}),
    },
  });
}

// Assemble the cf-aig-metadata payload from the route opts. AI Gateway
// caps custom metadata at 5 entries; we send at most 4.
function aigMetadataFrom(opts: RouteResolveOpts): Record<string, string> | undefined {
  const m: Record<string, string> = {};
  if (opts.taskType) m.task_type = opts.taskType;
  if (opts.metadata?.userId) m.user_id = opts.metadata.userId;
  if (opts.metadata?.conversationId) m.conversation_id = opts.metadata.conversationId;
  if (opts.metadata?.turnId) m.turn_id = opts.metadata.turnId;
  return Object.keys(m).length > 0 ? m : undefined;
}

export async function resolveRoute(
  supa: SupabaseClient,
  env: Env,
  opts: RouteResolveOpts,
): Promise<ResolvedRoute> {
  void supa; // no DB lookup — kept for signature stability across callers
  const slug = opts.modelSlug.trim();
  if (!slug) throw new NoRouteError('empty model slug');

  const providerSlug = resolveProviderSlug(opts.preferProvider);
  if (opts.excludeProviders?.includes(providerSlug)) {
    throw new NoRouteError(
      `provider ${providerSlug} is excluded and the passthrough router ` +
        `has no alternative route for ${slug}`,
    );
  }

  const baseURL = gatewayBaseUrl(env, providerSlug);
  const aigToken = env.CF_AIG_RUN_TOKEN;
  if (!aigToken) {
    throw new NoRouteError(
      'CF_AIG_RUN_TOKEN is not bound on the worker — set the AI Gateway ' +
        'run token secret (gateway Settings → Authenticated Gateway)',
    );
  }
  return {
    client: buildClient(env, baseURL, aigMetadataFrom(opts)),
    modelToCall: slug,
    provider: { slug: providerSlug, apiStyle: providerApiStyle(providerSlug) },
    baseURL,
    aigToken,
    byokAlias:
      providerSlug === 'google-ai-studio' ? env.GOOGLE_BYOK_ALIAS : undefined,
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
  // Per-task free-form metadata (bot_id, envelope_run_id, action, …).
  // Surfaced in audit_log.metadata jsonb so downstream queries can
  // group by these without bloating the column list.
  metadata?: Record<string, unknown> | null;
  /// External web search / scrape calls fired during this LLM turn,
  /// captured by WebToolMeter. Each entry lands in audit_web_tool_calls
  /// and sum(costUsd) folds into audit_log.tool_cost_usd + cost_credits
  /// so the single billing_debit covers both LLM and tool spend.
  webTools?: WebToolUsage[];
  /// Full prompt body sent to the model (message array or rendered string).
  /// Forwarded to Langfuse as the generation `input` so traces carry the
  /// real conversation, not just metrics. Never read by billing/DB — it
  /// only rides the queue message to traceGeneration. Omitted on paths
  /// that don't capture it (the trace still records metrics-only).
  promptBody?: unknown;
  /// Full completion text returned by the model. Forwarded to Langfuse as
  /// the generation `output`. Same lifecycle as promptBody.
  completionBody?: unknown;
  /// Langfuse prompt name (`<name>/<locale>`) + version of the main system
  /// prompt this turn used, so the trace links to its prompt version. Same
  /// lifecycle as promptBody (only rides the queue → traceGeneration).
  promptName?: string;
  promptVersion?: number;
}

const PER_MILLION = 1_000_000;

// Voice-call cost. OpenAI Realtime is a direct iOS↔OpenAI session that
// never flows through the worker or the AI Gateway, so there is no
// gateway log and no provider-reported cost to read. Its cost is computed
// here from the hand-maintained REALTIME_PRICING table × the token counts
// the realtime meter reports. Returns null for an unknown model slug —
// the turn then settles with no LLM cost. Every other task type bills via
// the gateway log (see persistAuditMessage).
export function computeVoiceCost(
  modelSlug: string | undefined,
  usage: AuditUsage,
): number | null {
  const price = modelSlug ? REALTIME_PRICING[modelSlug] : undefined;
  if (!price) return null;
  return (
    ((usage.inputTokens ?? 0) * price.inputPrice +
      (usage.outputTokens ?? 0) * price.outputPrice +
      (usage.cacheReadTokens ?? 0) * price.cachedInputPrice +
      (usage.audioInputTokens ?? 0) * price.audioInputPrice +
      (usage.audioOutputTokens ?? 0) * price.audioOutputPrice) /
    PER_MILLION
  );
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
      ? { modelToCall: route.modelToCall, provider: route.provider }
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
  // null when no route was ever successfully resolved (every fallback
  // attempt errored out before getting an OK from any provider). The
  // route_trace + status='error' still get persisted; cost_usd stays null.
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
      // Both routes to the ledger are gone. For a failed turn that means
      // the incident leaves no trace at all — say so loudly with the same
      // marker the fallback path uses, so the alert still fires.
      console.error(
        opts.status === 'error' ? AUDIT_DROPPED_MARKER : '[enqueueAudit]',
        'inline persist also failed',
        msg.auditId,
        err2,
      );
    }
  }
  return msg.auditId;
}

// Fixed marker for "a turn's audit row could not be written by either
// route". Distinct from FALLBACK_EXHAUSTED_MARKER: that one says the LLM
// call failed, this one says we also failed to record that it failed.
export const AUDIT_DROPPED_MARKER = '[audit-write-dropped]';

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
  //   2. voice_call — local price-book computation; OpenAI Realtime never
  //      flows through the gateway, so there is no gateway log to read.
  //   3. otherwise — the AI Gateway's computed cost, read from its Logs
  //      API by turn id (auditId is the value stamped into cf-aig-metadata).
  let llmCost = opts.providerCostUsd ?? null;
  if (llmCost == null && opts.taskType === 'voice_call') {
    llmCost = computeVoiceCost(route?.modelToCall, opts);
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
  // during the same LLM turn. We fold its USD sum into the parent
  // audit row for at-a-glance turn cost; the actual debit is per-call
  // via wallet.debit below (one WalletDO debit each). Per-call detail also
  // goes into audit_web_tool_calls.
  const toolCalls = opts.webTools ?? [];
  const toolCostUsd = toolCalls.reduce((s, c) => s + (c.costUsd || 0), 0);
  const hasTools = toolCalls.length > 0;
  // Combined raw USD for the audit row (informational). The authoritative
  // debit is WalletDO in PNC micros (usdToPncMicros) — no runtime markup
  // (markup lives only on sale-side pack issuance now).
  const combinedUsd = (llmCost ?? 0) + toolCostUsd;
  const total =
    (opts.inputTokens ?? 0) +
    (opts.outputTokens ?? 0) +
    (opts.cacheReadTokens ?? 0) +
    (opts.cacheWriteTokens ?? 0) +
    (opts.audioInputTokens ?? 0) +
    (opts.audioOutputTokens ?? 0);

  // Owner = final responsible subject (group/temp-group/crew → the conv's
  // responsible_subject_id pool wallet; else the initiating user). Same
  // resolver the pre-call gate uses, so gate-subject and debit-subject
  // never drift.
  // 解析失败(拿不到个人 user_account subject)→ 本回合不计费,并留报错级日志。
  // 宁可漏一笔账,也不猜一个键去扣 —— 扣到错的 DO 就是把钱记在无人认领的钱包上。
  let billingTarget: Awaited<ReturnType<typeof resolveBillingSubjectId>> = null;
  try {
    billingTarget = await resolveBillingSubjectId(supa, {
      conversationId: opts.conversationId,
      userId: opts.userId,
    });
  } catch (err) {
    console.error(
      '[persistAuditMessage] billing subject unresolved — turn left unbilled',
      opts.userId ?? null,
      (err as Error)?.message,
    );
  }
  const hasBillableTarget = billingTarget != null;

  // audit_log.billing_status is now a v1-legacy column kept only as turn
  // metadata (the real ledger is billing v2's ledger_entries). We stamp a
  // sensible terminal value on insert:
  //   - 'free'    : no billable owner at all (system/bot-only turn)
  //   - 'skipped' : billable owner but zero cost (error / no usage)
  //   - 'billed'  : wallet.debit will charge the owner's WalletDO this turn
  //
  // Failed turns (status='error') land on 'free'/'skipped' by construction:
  // the gateway-cost read above is gated on status==='success', so llmCost
  // stays null and combinedUsd only ever carries web-tool spend that was
  // genuinely consumed before the LLM threw. cost_usd stays null on those
  // rows too, so `sum(cost_usd)` dashboards are unaffected by error rows.
  const initialBilling: 'free' | 'skipped' | 'billed' = !hasBillableTarget
    ? 'free'
    : combinedUsd <= 0
      ? 'skipped'
      : 'billed';

  // Voice call dims land in dedicated columns so dashboards can split
  // "audio token spend" vs "text token spend" without re-deriving from
  // task_type. Both zero for text-only turns.
  const audioInputTokens = opts.audioInputTokens ?? 0;
  const audioOutputTokens = opts.audioOutputTokens ?? 0;

  const auditMetadata = opts.metadata
    ? { ...(opts.metadata as Record<string, Json>) }
    : {};
  if (billingTarget) {
    auditMetadata.billing_target_kind = billingTarget.kind;
    auditMetadata.billing_subject_id = billingTarget.subjectId;
  }

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
    // figure for this turn. tool_cost_usd breaks out web-tool spend.
    // cost_credits is v1-legacy (the real debit is WalletDO PNC micros);
    // left 0 so dashboards reading it don't double-count post-cutover.
    cost_usd: llmCost,
    tool_cost_usd: hasTools ? toolCostUsd : null,
    cost_credits: 0,
    billing_status: initialBilling,
    generation_id: opts.generationId ?? null,
    latency_ms: latencyMs,
    status: opts.status,
    error_class: opts.errorClass ?? null,
    route_trace: (opts.routeTrace as Json | null) ?? null,
    tag: opts.tag ?? null,
    ...(Object.keys(auditMetadata).length > 0 ? { metadata: auditMetadata as Json } : {}),
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

  // Post-insert debit (WalletDO authoritative — 计费 P2). One debit for the
  // model/voice spend + one per web-tool call, each against the resolved
  // owner's WalletDO (the DO decrements its cached balance + buffers the
  // usage to flush to Polar). Idempotent on dedupeId (auditId-derived), so
  // the at-least-once queue never double-charges; the fresh-insert guard
  // above also short-circuits duplicate deliveries before reaching here.
  // Failures are logged + swallowed — a billing hiccup must never break the
  // already-persisted, user-visible turn.
  if (initialBilling === 'billed' && billingTarget) {
    const subjectId = billingTarget.subjectId;
    const isGroup = billingTarget.kind === 'subject';
    const modelCategory = opts.taskType === 'voice_call' ? 'voice_tokens' : 'llm_tokens';
    // 群(kind=subject)走 settleGroupSpend:按份额拆实缴池(衰减 share_index)+ 认缴成员
    // 个人钱包直扣。个人(kind=user)走 wallet.debit。失败 log+吞,不破坏已落地的回合。
    const charge = async (micros: number, category: string, dedupeId: string, meta: Record<string, unknown>) => {
      if (micros <= 0) return;
      if (isGroup) {
        await settleGroupSpend({ env, supa, subjectId, spendMicros: micros, category, dedupeId, meta });
      } else {
        await wallet.debit(env, subjectId, micros, { category, dedupeId, meta });
      }
    };
    // 1. Model/voice spend(vendor cost, no markup)。
    const llmMicros = usdToPncMicros(llmCost ?? 0);
    try {
      await charge(llmMicros, modelCategory, auditId, {
        model_id: route?.modelToCall ?? opts.tag ?? '<unrouted>',
        provider: route?.provider?.slug ?? null,
        task_type: opts.taskType,
        total_tokens: total,
        cost_source: opts.providerCostUsd != null ? 'provider' : 'gateway',
        conversation_id: opts.conversationId ?? null,
      });
    } catch (err) {
      console.warn('[charge llm_tokens]', auditId, err instanceof Error ? err.message : String(err));
    }
    // 2. Web-tool calls — one charge each, dedupeId namespaced by call index。
    for (let i = 0; i < toolCalls.length; i++) {
      const tool = toolCalls[i];
      const micros = usdToPncMicros(tool.costUsd ?? 0);
      try {
        await charge(micros, 'web_tools', `${auditId}:tool:${i}`, {
          provider: tool.provider,
          kind: tool.kind,
          target: tool.target,
          status: tool.status,
          conversation_id: opts.conversationId ?? null,
        });
      } catch (err) {
        console.warn('[charge web_tools]', auditId, tool.provider, err instanceof Error ? err.message : String(err));
      }
    }
  }

  // LLM observability (Langfuse, dashboard block 2). Fires after the audit
  // row + billing land, on the fresh-insert path only (a duplicate queue
  // delivery returned early at the dedup guard above), so each turn traces
  // exactly once. Awaited — this is the queue consumer, not a request path —
  // but no-op + instant when Langfuse is disabled/unconfigured, and never
  // throws.
  //
  // Content: full prompt + completion bodies are forwarded when the caller
  // captured them (promptBody / completionBody), so Langfuse traces carry
  // the real conversation for debugging — not just metrics. Paths that
  // don't pass them (system cascades that didn't wire it up) still trace
  // metrics-only. Langfuse is self-hosted in the project's stack, so this
  // is first-party observability, not a third-party analytics export.
  await traceGeneration(env, {
    name: opts.taskType ?? 'llm_turn',
    model: route?.modelToCall ?? opts.tag ?? undefined,
    traceId: auditId,
    userId: opts.userId ?? undefined,
    sessionId: opts.conversationId ?? undefined,
    input: opts.promptBody,
    output: opts.completionBody,
    ...(opts.promptName && opts.promptVersion != null
      ? { prompt: { name: opts.promptName, version: opts.promptVersion } }
      : {}),
    usage: {
      input: opts.inputTokens ?? 0,
      output: opts.outputTokens ?? 0,
      total,
    },
    metadata: {
      task_type: opts.taskType,
      provider: route?.provider?.slug ?? null,
      status: opts.status,
      latency_ms: latencyMs,
      cost_usd: llmCost,
      cache_read_tokens: opts.cacheReadTokens ?? 0,
      cache_write_tokens: opts.cacheWriteTokens ?? 0,
      audio_input_tokens: audioInputTokens,
      audio_output_tokens: audioOutputTokens,
    },
  });
}

// Billing-owner resolution moved to billing/usage-gate.ts
// (resolveBillingSubjectId) so the pre-call gate and the post-call debit
// route through one resolver and can't drift.

// ============================================================
// Fallback orchestration
// ============================================================
//
// withFallback wraps resolveRoute + a runner closure (the actual
// completion call) in a retry loop. On a transient failure it pushes the
// provider into excludeProviders and re-resolves; in the passthrough
// model there is one provider per route, so a transient failure
// terminates the loop (resolveRoute throws NoRouteError for the excluded
// provider). The wrapper is kept so callers get a uniform route_trace and
// a single place that classifies errors.

export interface RouteTraceEntry {
  attempt: number;
  provider_slug: string;
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

// Fixed log marker for "every fallback attempt failed". Emitted from the
// single place that throws FallbackError, so no call site can forget it —
// grep / alert on this exact string to catch every exhausted LLM turn.
export const FALLBACK_EXHAUSTED_MARKER = '[llm-fallback-exhausted]';

/// The last real failure behind a FallbackError, flattened. `lastError`
/// and `routeTrace` have always been on the error object; nobody read
/// them, so every failure surfaced as the contentless "withFallback
/// exhausted (N attempts)". This is the one reader.
export interface FallbackFailure {
  errorClass: string;
  /// Upstream error text, already truncated to 200 chars by the trace.
  message: string;
  /// null when not even a route could be resolved (no provider reached).
  providerSlug: string | null;
  attempts: number;
}

export function describeFallbackFailure(err: FallbackError): FallbackFailure {
  const last = err.routeTrace[err.routeTrace.length - 1];
  return {
    errorClass: last?.error_class ?? 'unknown',
    message: last?.error_message ?? '',
    providerSlug:
      last && last.provider_slug !== NO_ROUTE_SLUG ? last.provider_slug : null,
    attempts: err.routeTrace.length,
  };
}

const NO_ROUTE_SLUG = '(no-route)';

// The FallbackError message itself carries the real cause: the class and
// text of the last failed attempt, plus which provider it was talking to.
// This string is what lands in worker logs AND (via bot-reply's `emit`)
// in the client's error alert, so "withFallback exhausted (1 attempt)"
// alone was a dead end for anyone debugging after the fact.
function fallbackMessage(routeTrace: RouteTraceEntry[]): string {
  const n = routeTrace.length;
  const head = `withFallback exhausted (${n} attempt${n === 1 ? '' : 's'})`;
  const last = routeTrace[n - 1];
  if (!last) return head;
  const where = last.provider_slug === NO_ROUTE_SLUG ? 'no route' : last.provider_slug;
  const detail = last.error_message ? `: ${last.error_message}` : '';
  return `${head} — last attempt [${where}] ${last.error_class ?? 'unknown'}${detail}`;
}

/// Audit fields for a failed LLM turn, derived the same way at every
/// call site. Both branches speak the classifyError vocabulary, so
/// `select error_class, count(*) from audit_log where status='error'`
/// groups cleanly regardless of which layer threw.
///
///   - FallbackError → the router gave up; route_trace shows every
///     attempt, `route` is the last one that resolved (null if none did).
///   - anything else → a throw from the runner body itself (mid-stream,
///     tool loop, JSON parse). No trace of our own; classify the error.
export function auditErrorFields(err: unknown): {
  route: ResolvedRoute | null;
  errorClass: string;
  routeTrace: RouteTraceEntry[] | undefined;
  message: string;
} {
  if (err instanceof FallbackError) {
    const failure = describeFallbackFailure(err);
    return {
      route: err.lastRoute,
      errorClass: failure.errorClass,
      routeTrace: err.routeTrace,
      message: failure.message || err.message,
    };
  }
  const cls = classifyError(err);
  return {
    route: null,
    errorClass: cls.errorClass,
    routeTrace: undefined,
    message: cls.message.slice(0, 200),
  };
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
        provider_slug: NO_ROUTE_SLUG,
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
        status: 'ok',
        latency_ms: Date.now() - attemptStart,
      });
      return { result, route, routeTrace };
    } catch (err) {
      const cls = classifyError(err);
      routeTrace.push({
        attempt,
        provider_slug: route.provider.slug,
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

  // One fixed-marker line per exhausted turn, before the throw — so the
  // failure is visible in `wrangler tail` / a log alert even on the paths
  // whose audit write is best-effort. Single JSON payload so a log query
  // can filter by error_class / provider without regex-ing prose.
  const last = routeTrace[routeTrace.length - 1];
  console.error(
    FALLBACK_EXHAUSTED_MARKER,
    JSON.stringify({
      task_type: opts.taskType ?? null,
      model_slug: opts.modelSlug,
      attempts: routeTrace.length,
      error_class: last?.error_class ?? 'unknown',
      provider: last?.provider_slug ?? null,
      message: last?.error_message ?? null,
      route_trace: routeTrace,
    }),
  );

  throw new FallbackError(fallbackMessage(routeTrace), {
    routeTrace,
    lastError,
    lastRoute,
  });
}
