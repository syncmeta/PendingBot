import { getSandbox } from '@cloudflare/sandbox';
import type { Env } from '../types';

// Thin wrapper over the Cloudflare Sandbox SDK. Each conversation gets its
// own container-backed Durable Object instance keyed by conversation_id —
// the SDK handles lifecycle (lazy start, idle sleep, eventual eviction)
// so this module is pure execution glue, no bookkeeping table needed.
//
// Python data-stack (numpy/pandas/matplotlib/pillow/requests/httpx/
// python-dateutil) is baked into apps/edge/Dockerfile, so a fresh
// sandbox can run user code on the very first call — no cold pip
// install. To extend the bootstrap set, edit the Dockerfile and
// redeploy; nothing here changes.

// Hard cap for code-run output. The chat agent loops on tool results, so
// huge stdout would balloon the prompt. 8 KiB per call is plenty for
// any reasonable interactive task.
const RESULT_TRUNCATE_CHARS = 8000;

// Per-call execution timeout passed to the SDK's runCode. 30s bounds
// runaway loops while leaving headroom for typical pandas/numpy steps.
const CODE_RUN_TIMEOUT_MS = 30_000;

// Idle window before the container auto-sleeps. The SDK accepts a
// duration string ("1m", "1h"). Billing matters here: a container is
// charged for memory+disk (provisioned) the whole time it stays in the
// *running* state — sleepAfter only delays the transition to *sleep*,
// during which there is no charge. A long window therefore means we pay
// for idle, abandoned conversations. code-exec is a rare tool, so we
// keep this short: 1m still covers an agent loop's back-to-back
// execute_code calls within a turn, then lets the container sleep.
const SANDBOX_SLEEP_AFTER = '1m';

export interface CodeRunResult {
  stdout: string;        // joined logs.stdout + logs.stderr + traceback, truncated
  exitCode: number;      // 0 on success, 1 if result.error is present
  truncated: boolean;
}

/// Run Python in this conversation's sandbox. State does NOT persist
/// across calls (each runCode invocation is its own interpreter session,
/// matching the model-facing tool description). Side effects on the
/// container filesystem do persist for the life of the sandbox.
export async function runPython(
  env: Env,
  conversationId: string,
  code: string,
  opts: { timeoutMs?: number } = {},
): Promise<CodeRunResult> {
  const sandbox = getSandbox(env.Sandbox, conversationId, {
    sleepAfter: SANDBOX_SLEEP_AFTER,
  });
  const result = await sandbox.runCode(code, {
    language: 'python',
    timeout: opts.timeoutMs ?? CODE_RUN_TIMEOUT_MS,
  });

  // Combine stdout + stderr + traceback into one stream — Daytona's
  // code-run returned a single `result` field and the chat agent's
  // tool contract still speaks in those terms. Trailing newline parity
  // with the previous wrapper.
  const parts: string[] = [];
  for (const line of result.logs.stdout) parts.push(line);
  for (const line of result.logs.stderr) parts.push(line);
  if (result.error) {
    parts.push(`${result.error.name}: ${result.error.message}`);
    if (result.error.traceback?.length) parts.push(result.error.traceback.join('\n'));
  }
  const raw = parts.join('');
  const truncated = raw.length > RESULT_TRUNCATE_CHARS;
  return {
    stdout: truncated ? raw.slice(0, RESULT_TRUNCATE_CHARS) : raw,
    exitCode: result.error ? 1 : 0,
    truncated,
  };
}

/// Best-effort destroy. Called when a conversation is torn down (e.g.
/// the cleanup path in routes/conversations); idle sandboxes auto-sleep
/// without us, so failures here are non-fatal.
export async function deleteSandbox(env: Env, conversationId: string): Promise<void> {
  try {
    const sandbox = getSandbox(env.Sandbox, conversationId);
    await sandbox.destroy();
  } catch (err) {
    console.warn('[sandbox] destroy failed', conversationId, err);
  }
}
