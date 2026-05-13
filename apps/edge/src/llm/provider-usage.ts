import type { Json } from '../db/schema';

export interface ProviderUsageDetails {
  providerCostUsd?: number | null;
  reportedProvider?: string | null;
  costDetails?: Json | null;
  promptTokensDetails?: Json | null;
  completionTokensDetails?: Json | null;
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
  completion_tokens_details?: unknown;
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

function firstString(...values: unknown[]): string | null {
  for (const v of values) {
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return null;
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === 'object' && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

function toJson(v: unknown): Json | null {
  if (v === undefined || v === null) return null;
  try {
    return JSON.parse(JSON.stringify(v)) as Json;
  } catch {
    return null;
  }
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
  const cacheWrite = finiteNumber(u.cache_creation_input_tokens) ?? 0;
  // promptTokens conventionally includes cached tokens. We split them
  // so accounting is non-overlapping: input = prompt - cache_read.
  const promptTotal = finiteNumber(u.prompt_tokens) ?? 0;
  const input = Math.max(0, promptTotal - (cacheRead ?? 0));

  return {
    inputTokens: input,
    outputTokens: finiteNumber(u.completion_tokens) ?? 0,
    cacheReadTokens: cacheRead ?? 0,
    cacheWriteTokens: cacheWrite,
    providerCostUsd: firstNumber(
      u.cost,
      u.cost_usd,
      u.total_cost,
      responseRecord?.cost,
      responseRecord?.cost_usd,
      costFromDetails(costDetails),
    ),
    reportedProvider: firstString(
      u.provider,
      u.provider_name,
      responseRecord?.provider,
      responseRecord?.provider_name,
    ),
    costDetails: toJson(u.cost_details),
    promptTokensDetails: toJson(u.prompt_tokens_details),
    completionTokensDetails: toJson(u.completion_tokens_details),
  };
}

function mergeJsonObjects(a: Json | null | undefined, b: Json | null | undefined): Json | null {
  const ar = asRecord(a);
  const br = asRecord(b);
  if (!ar) return b ?? null;
  if (!br) return a ?? null;
  const out: Record<string, Json> = {};
  for (const [k, v] of Object.entries(ar)) {
    if (v !== undefined) out[k] = v as Json;
  }
  for (const [k, v] of Object.entries(br)) {
    if (v === undefined) continue;
    const av = out[k];
    const an = finiteNumber(av);
    const bn = finiteNumber(v);
    out[k] = an != null && bn != null ? an + bn : (v as Json);
  }
  return out;
}

export function mergeProviderUsageDetails<T extends ProviderUsageDetails>(
  target: T,
  source: ProviderUsageDetails,
): T {
  if (source.providerCostUsd != null) {
    target.providerCostUsd = (target.providerCostUsd ?? 0) + source.providerCostUsd;
  }
  if (!target.reportedProvider && source.reportedProvider) {
    target.reportedProvider = source.reportedProvider;
  } else if (
    target.reportedProvider &&
    source.reportedProvider &&
    target.reportedProvider !== source.reportedProvider
  ) {
    target.reportedProvider = 'multiple';
  }
  target.costDetails = mergeJsonObjects(target.costDetails, source.costDetails);
  target.promptTokensDetails = mergeJsonObjects(
    target.promptTokensDetails,
    source.promptTokensDetails,
  );
  target.completionTokensDetails = mergeJsonObjects(
    target.completionTokensDetails,
    source.completionTokensDetails,
  );
  return target;
}
