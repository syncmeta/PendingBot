import type { SupabaseClient } from '../lib/supabase';
import { settleUsage, type EventCategory, type OwnerRef } from '../lib/billing-v2';
import type { WebToolUsage } from '../lib/web-meter';
import type { AuditMessage } from '../queue/audit-types';

// Dual-write: every successful turn that lands a v1 audit + debit also
// fires v2 settleUsage() calls. v1 stays authoritative until the cutover
// in #190; v2 builds parallel state so we can compare and switch.
//
// SCOPE (1v1 user-owner turns only — opts.userId set, no conversation
// subject). Group / temporary_group / Crew turns still flow v1-only; their
// v2 owner mapping lands with #190.
//
// Three usage_event shapes are recorded per qualifying turn:
//   1. The model spend            → category llm_tokens | voice_tokens
//   2. Each web-tool call         → category web_tools (one event per call)
//   (sandbox_runtime is a design-doc category but has NO v1 billing path
//    today — see docs/tech-debt.md; nothing to dual-write yet.)

// ---------------------------------------------------------------------------
// taskType → event category. Voice turns price audio tokens, so they get
// their own category; everything else that bills model tokens is llm_tokens.
// ---------------------------------------------------------------------------
export function modelEventCategory(taskType: string): EventCategory {
  return taskType === 'voice_call' ? 'voice_tokens' : 'llm_tokens';
}

export interface DualWriteV2Params {
  supa: SupabaseClient;
  msg: AuditMessage;
  ownerUserId: string;
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
 * Record v2 usage_events for a 1v1 turn: the model spend plus one event
 * per web-tool call. All failures are logged + swallowed — billing v2
 * dual-write must never break the authoritative v1 path.
 */
export async function dualWriteV2(params: DualWriteV2Params): Promise<void> {
  const {
    supa,
    msg,
    ownerUserId,
    modelCostUsd,
    totalTokens,
    modelId,
    providerSlug,
    costSource,
    webTools,
  } = params;

  const owner: OwnerRef = { kind: 'user', userId: ownerUserId };
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
