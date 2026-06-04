// Langfuse LLM-observability helper (dashboard stack).
//
// Env-gated: when LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY is unset,
// traceGeneration() returns immediately — a true no-op, so dev / preview
// deploys without Langfuse configured behave exactly as before. See
// docs/superpowers/specs/2026-06-01-dashboard-stack-design.md.
//
// This file intentionally only exposes a thin `traceGeneration()` helper.
// Wiring it into the actual LLM path (src/llm/*) is a separate, later step —
// this is just the seam, so the main chat loop is untouched for now.
//
// Workers note: the Langfuse SDK batches ingestion and flushes on a
// background timer that doesn't survive a torn-down isolate. We therefore
// call `flushAsync()` after recording, which awaits the pending batch send.

import { Langfuse } from 'langfuse';
import type { Env } from '../types';
import { langfuseEnabled } from './feature-flags';

export interface TraceGenerationArgs {
  /** Generation/observation name, e.g. 'chat_reply', 'title'. */
  name: string;
  /** Model identifier, e.g. 'gpt-4o', 'gemini-2.5-flash'. */
  model?: string;
  /** Prompt / input payload sent to the model (string or structured). */
  input?: unknown;
  /** Completion / output payload returned by the model. */
  output?: unknown;
  /** Token usage, e.g. { input, output, total }. */
  usage?: { input?: number; output?: number; total?: number };
  /** Free-form metadata attached to the generation. */
  metadata?: Record<string, unknown>;
  /** Optional grouping ids so generations roll up into one trace / user. */
  traceId?: string;
  userId?: string;
  sessionId?: string;
}

/**
 * Record a single LLM generation as a Langfuse trace + generation.
 *
 * No-op when either Langfuse key is unset. When set, creates a trace, attaches
 * one generation observation, and awaits the ingestion flush so the event
 * survives a short-lived Worker isolate.
 *
 * Never throws: tracing is best-effort and must not break the LLM call it's
 * observing. Failures are logged and swallowed.
 */
export async function traceGeneration(env: Env, args: TraceGenerationArgs): Promise<void> {
  if (!langfuseEnabled(env) || !env.LANGFUSE_PUBLIC_KEY || !env.LANGFUSE_SECRET_KEY) return;

  const langfuse = new Langfuse({
    publicKey: env.LANGFUSE_PUBLIC_KEY,
    secretKey: env.LANGFUSE_SECRET_KEY,
    baseUrl: env.LANGFUSE_BASE_URL,
  });

  try {
    const trace = langfuse.trace({
      id: args.traceId,
      name: args.name,
      userId: args.userId,
      sessionId: args.sessionId,
      metadata: args.metadata,
    });

    trace.generation({
      name: args.name,
      model: args.model,
      input: args.input,
      output: args.output,
      usage: args.usage,
      metadata: args.metadata,
    });

    // Await the batch send — the background flush timer won't fire once the
    // isolate is recycled after the response.
    await langfuse.flushAsync();
  } catch (err) {
    console.error('[llm-trace] traceGeneration failed', err);
  }
}
