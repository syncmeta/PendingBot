// Langfuse LLM-observability helper (dashboard stack).
//
// Env-gated: when LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY is unset,
// traceGeneration() returns immediately — a true no-op, so dev / preview
// deploys without Langfuse configured behave exactly as before. See
// docs/superpowers/specs/2026-06-01-dashboard-stack-design.md.
//
// Wired into the LLM path via the audit queue: enqueueAudit (src/llm/router.ts)
// forwards the prompt/completion/usage, and persistAuditMessage calls
// traceGeneration() off the response path. A generation can also link to its
// Langfuse prompt version (args.prompt) for version-level analytics. The
// shared Langfuse client lives in ./langfuse-client (reused by prompt-loader).
//
// Workers note: the Langfuse SDK batches ingestion and flushes on a
// background timer that doesn't survive a torn-down isolate. We therefore
// call `flushAsync()` after recording, which awaits the pending batch send.

import type { LangfusePromptRecord } from 'langfuse';
import type { Env } from '../types';
import { langfuseEnabled } from './feature-flags';
import { getLangfuseClient } from './langfuse-client';

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
  /**
   * Link this generation to its Langfuse prompt version (enables analytics by
   * prompt version). `name` is the Langfuse prompt name (`<name>/<locale>`).
   */
  prompt?: { name: string; version: number };
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
  if (!(await langfuseEnabled(env))) return;
  const langfuse = getLangfuseClient(env);
  if (!langfuse) return;

  try {
    const trace = langfuse.trace({
      id: args.traceId,
      name: args.name,
      userId: args.userId,
      sessionId: args.sessionId,
      metadata: args.metadata,
    });

    // Minimal record carrying just name + version — the SDK lifts those onto
    // the generation's promptName/promptVersion for version-level analytics.
    const promptLink: LangfusePromptRecord | undefined = args.prompt
      ? {
          name: args.prompt.name,
          version: args.prompt.version,
          prompt: '',
          type: 'text',
          config: {},
          labels: [],
          tags: [],
          isFallback: false,
        }
      : undefined;

    trace.generation({
      name: args.name,
      model: args.model,
      input: args.input,
      output: args.output,
      usage: args.usage,
      metadata: args.metadata,
      ...(promptLink ? { prompt: promptLink } : {}),
    });

    // Await the batch send — the background flush timer won't fire once the
    // isolate is recycled after the response.
    await langfuse.flushAsync();
  } catch (err) {
    console.error('[llm-trace] traceGeneration failed', err);
  }
}

export interface RecordScoreArgs {
  /** Score name, e.g. 'arena_preference'. Becomes the Langfuse score key. */
  name: string;
  /**
   * Score value. Numeric (any float) or categorical (string label). For an
   * arena A/B/tie vote we use a categorical label ('a' | 'b' | 'tie') plus a
   * numeric mapping so the score is both filterable and aggregatable.
   */
  value: number | string;
  /** Optional explicit dataType; inferred from `value` when omitted. */
  dataType?: 'NUMERIC' | 'CATEGORICAL' | 'BOOLEAN';
  /** Trace this score attaches to. A fresh trace is created if it doesn't exist. */
  traceId: string;
  /** Trace display name when this call creates the trace. */
  traceName?: string;
  userId?: string;
  sessionId?: string;
  /** Free-form note surfaced on the score in the Langfuse UI. */
  comment?: string;
  /** Metadata attached to the (auto-created) trace. */
  metadata?: Record<string, unknown>;
}

/**
 * Emit a single Langfuse score, ensuring a trace exists for it to hang on.
 *
 * Same env-gating + best-effort contract as traceGeneration: no-op when
 * Langfuse is disabled / unconfigured, never throws. Used for human-feedback
 * signals (e.g. arena A/B preference votes) that aren't tied to a generation.
 */
export async function recordScore(env: Env, args: RecordScoreArgs): Promise<void> {
  if (!(await langfuseEnabled(env))) return;
  const langfuse = getLangfuseClient(env);
  if (!langfuse) return;

  try {
    // Ensure the trace exists so the score has an anchor in the UI. trace()
    // is an upsert on id, so re-voting (same traceId) updates rather than
    // duplicates.
    langfuse.trace({
      id: args.traceId,
      name: args.traceName ?? args.name,
      userId: args.userId,
      sessionId: args.sessionId,
      metadata: args.metadata,
    });

    langfuse.score({
      traceId: args.traceId,
      name: args.name,
      value: args.value,
      dataType: args.dataType,
      comment: args.comment,
    });

    await langfuse.flushAsync();
  } catch (err) {
    console.error('[llm-trace] recordScore failed', err);
  }
}
