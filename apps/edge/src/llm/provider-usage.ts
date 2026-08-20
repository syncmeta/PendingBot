export interface ProviderUsageDetails {
  providerCostUsd?: number | null;
}

export interface CompletionUsageStats extends ProviderUsageDetails {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
}

type UsageLike = {
  prompt_tokens?: number | null;
  completion_tokens?: number | null;
  total_tokens?: number | null;
  prompt_tokens_details?: unknown;
  cost_details?: unknown;
  cache_creation_input_tokens?: number | null;
  cache_read_input_tokens?: number | null;
  [key: string]: unknown;
};

function finiteNumber(v: unknown): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : null;
}

function firstNumber(...values: unknown[]): number | null {
  for (const v of values) {
    const n = finiteNumber(v);
    if (n != null) return n;
  }
  return null;
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === 'object' && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

function costFromDetails(details: Record<string, unknown> | null): number | null {
  if (!details) return null;
  return firstNumber(
    details.total,
    details.total_cost,
    details.cost,
    details.cost_usd,
    details.upstream_cost,
    details.upstream_inference_cost,
  );
}

export function usageFromCompletion(
  usage: unknown | null | undefined,
  response?: unknown,
): CompletionUsageStats {
  const u = asRecord(usage) as UsageLike | null;
  if (!u) return {};
  const responseRecord = asRecord(response);
  const costDetails = asRecord(u.cost_details);
  const promptDetails = asRecord(u.prompt_tokens_details);
  const cacheRead =
    finiteNumber(u.cache_read_input_tokens) ??
    finiteNumber(promptDetails?.cached_tokens) ??
    0;
  // Cache writes: Anthropic-native reports cache_creation_input_tokens at the
  // top level; OpenRouter reports it as prompt_tokens_details.cache_write_tokens
  // (only present for models with explicit caching + cache-write pricing). The
  // OpenAI Responses / Gemini paths set neither, so this is a no-op for them.
  const cacheWrite =
    finiteNumber(u.cache_creation_input_tokens) ??
    finiteNumber(promptDetails?.cache_write_tokens) ??
    0;
  // promptTokens conventionally includes cached tokens. We split them
  // so accounting is non-overlapping: input = prompt - cache_read.
  const promptTotal = finiteNumber(u.prompt_tokens) ?? 0;
  const input = Math.max(0, promptTotal - (cacheRead ?? 0));

  return {
    inputTokens: input,
    outputTokens: finiteNumber(u.completion_tokens) ?? 0,
    cacheReadTokens: cacheRead ?? 0,
    cacheWriteTokens: cacheWrite,
    // The provider-reported cost — the exact amount the upstream charged.
    // Drives billing (see persistAuditMessage). Found under a few field
    // names across providers, or nested in cost_details.
    providerCostUsd: firstNumber(
      u.cost,
      u.cost_usd,
      u.total_cost,
      responseRecord?.cost,
      responseRecord?.cost_usd,
      costFromDetails(costDetails),
    ),
  };
}

// Sum providerCostUsd across a turn's LLM calls (tool loops, fallback
// retries) so a multi-call turn bills the total.
export function mergeProviderUsageDetails<T extends ProviderUsageDetails>(
  target: T,
  source: ProviderUsageDetails,
): T {
  if (source.providerCostUsd != null) {
    target.providerCostUsd = (target.providerCostUsd ?? 0) + source.providerCostUsd;
  }
  return target;
}
