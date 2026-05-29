import type { SupabaseClient } from '../lib/supabase';
import { settleUsage, type EventCategory, type OwnerRef } from '../lib/billing-v2';
import type { WebToolUsage } from '../lib/web-meter';
import type { AuditMessage } from '../queue/audit-types';

// Authoritative v2 turn settle (post-cutover #190). Every successful turn
// settles the model spend + each web-tool call against the owner's packs.
// This is THE debit now — v1 billingDebit/splitAndDebit are gone.
//
// Owner is resolved by the caller (router.persistAuditMessage):
//   - 1v1 / system turns        → user packs
//   - temporary_group / crew    → responsible subject packs
//   - group                     → group's responsible subject (pool) packs
//
// Two usage_event shapes per turn:
//   1. The model spend            → category llm_tokens | voice_tokens
//   2. Each web-tool call         → category web_tools (one event per call)
//   (sandbox_runtime is a design-doc category but has NO billing path yet
//    — see docs/tech-debt.md.)

// ---------------------------------------------------------------------------
// taskType → event category. Voice turns price audio tokens, so they get
// their own category; everything else that bills model tokens is llm_tokens.
// ---------------------------------------------------------------------------
export function modelEventCategory(taskType: string): EventCategory {
  return taskType === 'voice_call' ? 'voice_tokens' : 'llm_tokens';
}

export interface SettleTurnV2Params {
  supa: SupabaseClient;
  msg: AuditMessage;
  owner: OwnerRef;
  /** The model/voice USD cost for this turn (llmCost in persistAuditMessage). */
  modelCostUsd: number | null;
  totalTokens: number;
  modelId: string;
  providerSlug: string | null;
  costSource: 'gateway' | 'provider';
  /** Web-tool calls made during this turn (opts.webTools). */
  webTools: WebToolUsage[];
}

/**
 * Settle a turn's model spend + web-tool calls against the owner's packs.
 * All failures are logged + swallowed — a billing failure must never
 * break the user-visible turn (the audit_log row already persisted).
 */
export async function settleTurnV2(params: SettleTurnV2Params): Promise<void> {
  const {
    supa,
    msg,
    owner,
    modelCostUsd,
    totalTokens,
    modelId,
    providerSlug,
    costSource,
    webTools,
  } = params;

  const conversationId = msg.opts.conversationId ?? null;

  // 1. Model spend (LLM or voice). Skip free/zero-cost turns.
  if (modelCostUsd && modelCostUsd > 0) {
    const category = modelEventCategory(msg.opts.taskType);
    try {
      const result = await settleUsage(supa, {
        owner,
        category,
        provider: providerSlug ?? 'unknown',
        vendorSku: null,
        modelId,
        quantity: totalTokens,
        quantityUnit: 'tokens',
        vendorCostUsd: modelCostUsd,
        costSource,
        conversationId,
        auditLogId: msg.auditId,
        rawUsage: {
          input_tokens: msg.opts.inputTokens ?? 0,
          output_tokens: msg.opts.outputTokens ?? 0,
          cache_read_tokens: msg.opts.cacheReadTokens ?? 0,
          cache_write_tokens: msg.opts.cacheWriteTokens ?? 0,
          audio_input_tokens: msg.opts.audioInputTokens ?? 0,
          audio_output_tokens: msg.opts.audioOutputTokens ?? 0,
          task_type: msg.opts.taskType,
          generation_id: msg.opts.generationId ?? null,
        },
      });
      console.log(
        '[billing-v2 dualwrite]',
        msg.auditId,
        category,
        'billed',
        result.pncMicrosBilled,
        'overdraft',
        result.pncMicrosOverdrawn,
        'state',
        result.thresholdState,
      );
    } catch (err) {
      console.warn(
        '[billing-v2 dualwrite] model settle failed',
        msg.auditId,
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  // 2. Web-tool calls — one usage_event per call so the per-call detail
  //    the design doc §6 wants lives in usage_events, not folded into a
  //    parent row. Only successful, priced calls bill (errors cost 0).
  for (const tool of webTools) {
    if (!tool.costUsd || tool.costUsd <= 0) continue;
    try {
      await settleUsage(supa, {
        owner,
        category: 'web_tools',
        provider: tool.provider,
        vendorSku: tool.kind,
        modelId: null,
        quantity: 1,
        quantityUnit: 'calls',
        vendorCostUsd: tool.costUsd,
        costSource: 'local_pricebook',
        conversationId,
        auditLogId: msg.auditId,
        rawUsage: {
          kind: tool.kind,
          target: tool.target,
          status: tool.status,
          result_count: tool.resultCount ?? null,
          latency_ms: tool.latencyMs,
        },
      });
    } catch (err) {
      console.warn(
        '[billing-v2 dualwrite] web-tool settle failed',
        msg.auditId,
        tool.provider,
        err instanceof Error ? err.message : String(err),
      );
    }
  }
}
