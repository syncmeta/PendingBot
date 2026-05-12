import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { bootstrapPython, createSandbox, runPython } from '../../sandbox';
import type { ToolCtx } from '../tool-runner';

// How often the request_execute_code tool re-checks the DB for an iOS
// decision, and how long we wait before giving up. 500ms keeps perceived
// latency tight; 120s is plenty for a human to read a card and decide.
const CODE_EXEC_POLL_INTERVAL_MS = 500;
const CODE_EXEC_DECISION_TIMEOUT_MS = 120_000;

// Get-or-create a bootstrapped Daytona sandbox for this conversation.
// First call lazily provisions + pip-installs the common data-stack;
// subsequent calls reuse the same VM. The cron sweep retires idle
// sandboxes — on retirement we'd lose interpreter state, but bootstrap
// is idempotent so the next call just re-provisions.
//
// Returns either { sandboxId } once the sandbox is ready, or
// { error, stderr } if bootstrap blew up (caller turns that into a tool
// error envelope so the model can recover).
async function getOrBootstrapSandbox(
  env: Env,
  conversationId: string,
): Promise<
  | { sandboxId: string }
  | { error: 'bootstrap_failed'; exitCode: number; stderr: string }
> {
  const supa = serviceClient(env);

  // bot_sandbox_sessions has a UNIQUE on conversation_id so the
  // get-or-create race resolves to a single row.
  const existing = await supa
    .from('bot_sandbox_sessions')
    .select('daytona_sandbox_id, bootstrapped')
    .eq('conversation_id', conversationId)
    .maybeSingle();

  let sandboxId: string;
  let bootstrapped: boolean;
  if (existing.data) {
    sandboxId = existing.data.daytona_sandbox_id;
    bootstrapped = existing.data.bootstrapped;
  } else {
    sandboxId = await createSandbox(env);
    await supa.from('bot_sandbox_sessions').insert({
      conversation_id: conversationId,
      daytona_sandbox_id: sandboxId,
      bootstrapped: false,
    });
    bootstrapped = false;
  }

  if (!bootstrapped) {
    const boot = await bootstrapPython(env, sandboxId);
    if (boot.exitCode === 0) {
      await supa
        .from('bot_sandbox_sessions')
        .update({ bootstrapped: true, last_used_at: new Date().toISOString() })
        .eq('conversation_id', conversationId);
    } else {
      // Keep the sandbox row so we don't churn through creates on every
      // retry; let the caller surface the failure to the model.
      return {
        error: 'bootstrap_failed',
        exitCode: boot.exitCode,
        stderr: boot.stdout.slice(-1000),
      };
    }
  }

  return { sandboxId };
}

// Run Python in this conversation's sandbox without user approval. Only
// reachable when a subscribed skill has opted in via allowed_tools.
export async function executeCodeTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const code = String(args.code ?? '');
  if (!code.trim()) return JSON.stringify({ error: 'code is required' });

  // First non-empty line of code, capped at 80 chars — gives the chat
  // trace something concrete to show ("import pandas as pd …") rather
  // than a bare byte count.
  const codePreview = code
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.length > 0)
    ?.slice(0, 80) ?? '';
  ctx.emit('tool_call', {
    name: 'execute_code',
    chars: code.length,
    code_preview: codePreview,
  });

  const sandbox = await getOrBootstrapSandbox(env, ctx.conversationId);
  if ('error' in sandbox) {
    ctx.emit('tool_result', {
      name: 'execute_code',
      error: 'sandbox bootstrap failed',
      exit_code: sandbox.exitCode,
    });
    return JSON.stringify({
      error: 'sandbox bootstrap failed',
      stderr: sandbox.stderr,
    });
  }

  const supa = serviceClient(env);
  const result = await runPython(env, sandbox.sandboxId, code);
  await supa
    .from('bot_sandbox_sessions')
    .update({ last_used_at: new Date().toISOString() })
    .eq('conversation_id', ctx.conversationId);

  // Tail of stdout (last ~160 chars, single-lined) so the expanded trace
  // shows what actually printed. Full stdout still goes back to the model
  // via the JSON return — this is purely a UI summary.
  const stdoutTail = result.stdout
    .slice(-160)
    .replace(/\s+/g, ' ')
    .trim();
  ctx.emit('tool_result', {
    name: 'execute_code',
    exit_code: result.exitCode,
    truncated: result.truncated,
    stdout_tail: stdoutTail,
  });
  return JSON.stringify({
    stdout: result.stdout,
    exit_code: result.exitCode,
    truncated: result.truncated,
  });
}

// User-approval-gated counterpart to execute_code. Inserts a pending row
// into bot_code_exec_requests, emits a `code_exec_request` SSE event so
// iOS can render the confirmation card, then short-polls the row until
// the user taps a button (POST /v1/code-exec-requests/:id/respond
// flips status) or the 120s budget runs out. On `approved` it runs the
// code in this conversation's sandbox and returns combined results to
// the model; on `denied`/`timeout` it returns just the decision so the
// bot can pivot.
export async function requestExecuteCodeTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const code = String(args.code ?? '');
  const reason = String(args.reason ?? '').trim();
  // estimated_seconds may arrive as number or stringified-number (some
  // models stringify ints in tool args). Coerce defensively.
  const rawEst = args.estimated_seconds;
  const estimated = typeof rawEst === 'number'
    ? Math.round(rawEst)
    : Math.round(Number(rawEst ?? 0));

  if (!code.trim()) return JSON.stringify({ error: 'code is required' });
  if (!reason) return JSON.stringify({ error: 'reason is required' });
  if (!Number.isFinite(estimated) || estimated < 0 || estimated > 600) {
    return JSON.stringify({ error: 'estimated_seconds must be 0..600' });
  }

  const supa = serviceClient(env);

  // Create the pending row first. iOS uses this row's id both as the
  // approval card's identifier and as the path param it POSTs back to.
  const insert = await supa
    .from('bot_code_exec_requests')
    .insert({
      conversation_id: ctx.conversationId,
      user_id: ctx.userId,
      bot_id: ctx.botId,
      code,
      reason,
      estimated_seconds: estimated,
    })
    .select('id')
    .single();
  if (insert.error || !insert.data) {
    const msg = insert.error?.message ?? 'failed to create approval request';
    ctx.emit('tool_result', { name: 'request_execute_code', error: msg });
    return JSON.stringify({ error: msg });
  }
  const requestId = (insert.data as { id: string }).id;

  // Tell iOS to render the confirmation card. Includes the full code
  // (so user can preview), reason, ETA, and the request id (used both
  // for visual identity and to address the POST decision endpoint).
  ctx.emit('tool_call', {
    name: 'request_execute_code',
    request_id: requestId,
    code,
    reason,
    estimated_seconds: estimated,
  });

  // Poll for decision. The Worker happily holds the SSE response open
  // while we wait — no DOs needed. Caller's signal aborting (user
  // closed the chat tab) cuts us out of the wait promptly.
  const decision = await pollCodeExecDecision(env, requestId, ctx.signal);

  if (decision === 'denied') {
    ctx.emit('tool_result', {
      name: 'request_execute_code',
      request_id: requestId,
      decision: 'denied',
    });
    return JSON.stringify({
      approved: false,
      decision: 'denied',
      hint: '用户拒绝了这次代码执行。换个不需要跑代码的思路，或者在确认能解决问题后再问一次。',
    });
  }
  if (decision === 'timeout') {
    ctx.emit('tool_result', {
      name: 'request_execute_code',
      request_id: requestId,
      decision: 'timeout',
    });
    return JSON.stringify({
      approved: false,
      decision: 'timeout',
      hint: '120 秒内用户没有回应。可以先回复一句话提醒，或者换条不依赖执行代码的路径。',
    });
  }
  if (decision === 'aborted') {
    // Caller's AbortSignal fired (user closed the chat). Don't run code,
    // just bail. The audit/error path upstream already reflects abort.
    return JSON.stringify({ approved: false, decision: 'aborted' });
  }

  // approved → run the code.
  const sandbox = await getOrBootstrapSandbox(env, ctx.conversationId);
  if ('error' in sandbox) {
    ctx.emit('tool_result', {
      name: 'request_execute_code',
      request_id: requestId,
      decision: 'approved',
      error: 'sandbox bootstrap failed',
      exit_code: sandbox.exitCode,
    });
    return JSON.stringify({
      approved: true,
      decision: 'approved',
      error: 'sandbox bootstrap failed',
      stderr: sandbox.stderr,
    });
  }

  const result = await runPython(env, sandbox.sandboxId, code);
  await supa
    .from('bot_sandbox_sessions')
    .update({ last_used_at: new Date().toISOString() })
    .eq('conversation_id', ctx.conversationId);

  const stdoutTail = result.stdout
    .slice(-160)
    .replace(/\s+/g, ' ')
    .trim();
  ctx.emit('tool_result', {
    name: 'request_execute_code',
    request_id: requestId,
    decision: 'approved',
    exit_code: result.exitCode,
    truncated: result.truncated,
    stdout_tail: stdoutTail,
  });
  return JSON.stringify({
    approved: true,
    decision: 'approved',
    stdout: result.stdout,
    exit_code: result.exitCode,
    truncated: result.truncated,
  });
}

// Poll the bot_code_exec_requests row until status leaves 'pending', the
// caller's signal aborts, or our budget runs out. Returns a discriminator
// the caller maps to the model-facing response. On timeout we also flip
// the row to 'timeout' so a stale POST from iOS later finds it already
// resolved (no zombie cards).
async function pollCodeExecDecision(
  env: Env,
  requestId: string,
  signal: AbortSignal,
): Promise<'approved' | 'denied' | 'timeout' | 'aborted'> {
  const supa = serviceClient(env);
  const deadline = Date.now() + CODE_EXEC_DECISION_TIMEOUT_MS;

  while (true) {
    if (signal.aborted) return 'aborted';

    const { data } = await supa
      .from('bot_code_exec_requests')
      .select('status')
      .eq('id', requestId)
      .maybeSingle();
    const status = (data as { status?: string } | null)?.status;
    if (status === 'approved') return 'approved';
    if (status === 'denied') return 'denied';

    if (Date.now() >= deadline) {
      // Best-effort: stamp the row so a late POST from iOS sees a
      // resolved request and the card can dismiss itself. Race-safe via
      // status='pending' guard so we don't clobber a decision that
      // landed in the same tick.
      await supa
        .from('bot_code_exec_requests')
        .update({ status: 'timeout', responded_at: new Date().toISOString() })
        .eq('id', requestId)
        .eq('status', 'pending');
      return 'timeout';
    }

    // Wait, but bail early if the caller aborts mid-sleep.
    await new Promise<void>((resolve) => {
      const t = setTimeout(() => {
        signal.removeEventListener('abort', onAbort);
        resolve();
      }, CODE_EXEC_POLL_INTERVAL_MS);
      const onAbort = () => {
        clearTimeout(t);
        resolve();
      };
      signal.addEventListener('abort', onAbort, { once: true });
    });
  }
}
