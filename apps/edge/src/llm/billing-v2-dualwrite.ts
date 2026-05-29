import type { SupabaseClient } from '../lib/supabase';
import { settleUsage, type EventCategory, type OwnerRef } from '../lib/billing-v2';
import type { AuditMessage } from '../queue/audit-types';

// Dual-write: every successful turn that lands a v1 audit + debit also
// fires a v2 settleUsage(). v1 stays authoritative until the cutover in
// #190; v2 builds parallel state so we can compare and switch.
//
// SCOPE for this branch (intentionally narrow):
//   - 1v1 user-owner turns (opts.userId set, no conversation subject)
//   - LLM cost only — web/server-side tools land in #183 alongside the
//     dedicated voice/sandbox paths
//
// Group / temporary_group / Crew turns still flow through v1 only; their
// v2 path needs a clearer "group subject == billing subject" mapping
// decided by the next round.

export interface DualWriteV2LlmParams {
  supa: SupabaseClient;
  msg: AuditMessage;
  ownerUserId: string;
  llmCostUsd: number | null;
  totalTokens: number;
  modelId: string;
  providerSlug: string | null;
  costSource: 'gateway' | 'provider';
}

export async function dualWriteV2Llm(
  params: DualWriteV2LlmParams,
): Promise<void> {
  const {
    supa,
    msg,
    ownerUserId,
    llmCostUsd,
    totalTokens,
    modelId,
    providerSlug,
    costSource,
  } = params;

  if (!llmCostUsd || llmCostUsd <= 0) return; // free / skipped turn — nothing to record

  const owner: OwnerRef = { kind: 'user', userId: ownerUserId };
  const category: EventCategory = 'llm_tokens';

  try {
    const result = await settleUsage(supa, {
      owner,
      category,
      provider: providerSlug ?? 'unknown',
      vendorSku: null,
      modelId,
      quantity: totalTokens,
      quantityUnit: 'tokens',
      vendorCostUsd: llmCostUsd,
      costSource,
      conversationId: msg.opts.conversationId ?? null,
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
      'billed',
      result.pncMicrosBilled,
      'overdraft',
      result.pncMicrosOverdrawn,
      'state',
      result.thresholdState,
    );
  } catch (err) {
    // Dual-write must never break the v1 path. Log and move on.
    console.warn(
      '[billing-v2 dualwrite] settle failed',
      msg.auditId,
      err instanceof Error ? err.message : String(err),
    );
  }
}
