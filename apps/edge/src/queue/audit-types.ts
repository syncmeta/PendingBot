import type { AuditCallOpts, ResolvedRoute } from '../llm/router';

// Wire shape of a message on AUDIT_QUEUE. Everything here must be
// structured-clone-safe — Cloudflare Queues serializes the body — so
// the two non-serializable members of the inline-call inputs are
// dropped before enqueue:
//   - ResolvedRoute.client (an OpenAI SDK instance) → StrippedRoute
//   - AuditCallOpts.env (the worker bindings) → the consumer has its
//     own env, so it's omitted here
//
// `latencyMs` is computed at enqueue time. The consumer can't derive
// it from `startedAt` because it runs minutes later — Date.now() in
// the consumer would massively overstate latency.

// ResolvedRoute minus the live OpenAI client and the native-adapter
// gateway coordinates (baseURL / aigToken — the latter is a secret that
// must never ride a queue message). persistAuditMessage only ever reads
// modelToCall / provider, so nothing of value is lost.
export type StrippedRoute = Omit<ResolvedRoute, 'client' | 'baseURL' | 'aigToken'>;

// AuditCallOpts minus the worker Env (rebuilt consumer-side).
export type SerializableAuditOpts = Omit<AuditCallOpts, 'env'>;

export interface AuditMessage {
  // Producer-generated uuidv7. Becomes audit_log.id, and doubles as
  // the consumer's idempotency key (insert is upsert/ignoreDuplicates
  // on this id; a duplicate delivery is a no-op).
  auditId: string;
  // Wall-clock latency of the LLM turn, measured at enqueue time.
  latencyMs: number;
  // null when no provider could be resolved (NoRouteError) — the audit
  // row still records status='error' with cost left null.
  route: StrippedRoute | null;
  opts: SerializableAuditOpts;
}
