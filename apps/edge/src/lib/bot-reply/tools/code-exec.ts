import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { runPython, SandboxGateError } from '../../sandbox';
import type { ToolCtx } from '../tool-runner';

// How often the request_execute_code tool re-checks the DB for an iOS
// decision, and how long we wait before giving up. 500ms keeps perceived
// latency tight; 120s is plenty for a human to read a card and decide.
const CODE_EXEC_POLL_INTERVAL_MS = 500;
const CODE_EXEC_DECISION_TIMEOUT_MS = 120_000;

// Run Python in this conversation's sandbox without user approval. Only
// reachable when a subscribed skill has opted in via allowed_tools.
//
// The Cloudflare Sandbox SDK keys sandboxes by name (we use the
// conversation_id), so there's no DB lookup here — `getSandbox` is
// idempotent and lazily provisions on first use.
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

  let result;
  try {
    result = await runPython(env, ctx.conversationId, code, {
      meter: { userId: ctx.userId },
    });
  } catch (err) {
    if (err instanceof SandboxGateError) {
      ctx.emit('tool_result', {
        name: 'execute_code',
        error: err.message,
      });
      return JSON.stringify({
        error: 'balance_exhausted',
        message: err.message,
        hint: '余额已用完，无法执行代码。请提示用户充值，或换一条不需要跑代码的思路。',
      });
    }
    throw err;
  }

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
    error: result.exitCode === 0 ? undefined : `code exited with status ${result.exitCode}`,
    truncated: result.truncated,
    stdout_tail: stdoutTail,
    detail: result.exitCode === 0 ? undefined : result.stdout,
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
  const codePreview = code
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.length > 0)
    ?.slice(0, 80) ?? '';
  ctx.emit('tool_call', {
    name: 'request_execute_code',
    request_id: requestId,
    code,
    chars: code.length,
    code_preview: codePreview,
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
  let result;
  try {
    result = await runPython(env, ctx.conversationId, code, {
      meter: { userId: ctx.userId },
    });
  } catch (err) {
    if (err instanceof SandboxGateError) {
      ctx.emit('tool_result', {
        name: 'request_execute_code',
        request_id: requestId,
        decision: 'approved',
        error: err.message,
      });
      return JSON.stringify({
        approved: true,
        decision: 'approved',
        error: 'balance_exhausted',
        message: err.message,
        hint: '用户已批准，但余额已用完，无法执行。请提示用户充值。',
      });
    }
    throw err;
  }

  const stdoutTail = result.stdout
    .slice(-160)
    .replace(/\s+/g, ' ')
    .trim();
  ctx.emit('tool_result', {
    name: 'request_execute_code',
    request_id: requestId,
    decision: 'approved',
    exit_code: result.exitCode,
    error: result.exitCode === 0 ? undefined : `code exited with status ${result.exitCode}`,
    truncated: result.truncated,
    stdout_tail: stdoutTail,
    detail: result.exitCode === 0 ? undefined : result.stdout,
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
