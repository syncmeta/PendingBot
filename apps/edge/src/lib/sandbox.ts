import { getSandbox } from '@cloudflare/sandbox';
import type { Env } from '../types';
import type { SupabaseClient } from './supabase';
import { serviceClient } from './supabase';
import { wallet } from '../billing/wallet-client';
import { resolveUserWalletSubjectId } from '../billing/subject-key';
import { settleGroupSpend } from '../billing/group-wallet';
import { usdToPncMicros } from '../billing/pnc';

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

// ⚠️ TODO(pricing — UNDECIDED): placeholder per-second USD cost for a
// running sandbox container. This is a PRODUCT PRICING DECISION that has
// NOT been made — Cloudflare does not publish a per-second Sandbox price
// the worker can ingest, and the SDK's runCode result carries no
// duration/resource fields (verified against the official Sandbox SDK
// docs, 2026-06: ExecutionResult = { code, logs, results, error,
// executionCount } — no timing). We therefore meter on wall-clock
// seconds (Date.now() start/end) and multiply by this placeholder.
//
// Before launch this MUST be replaced with a real figure derived from
// Cloudflare's container memory+disk pricing for the *running* state
// (containers are billed for provisioned memory+disk the whole time they
// stay running, not per-exec). See docs/tech-debt.md "sandbox runtime
// pricebook". 0.0001 USD/s ≈ 0.36 USD/hour is an intentionally rough
// stand-in, not a committed number.
const SANDBOX_USD_PER_SECOND = 0.0001;

/// Thrown by runPython when the billing subject's wallet is exhausted
/// (thresholdState === 'exhausted'). The tool layer catches this and
/// surfaces a clear "balance used up" message to the model instead of
/// running code we can't charge for.
export class SandboxGateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SandboxGateError';
  }
}

export interface CodeRunResult {
  stdout: string;        // joined logs.stdout + logs.stderr + traceback, truncated
  exitCode: number;      // 0 on success, 1 if result.error is present
  truncated: boolean;
}

/// Resolve the billing subject id for a conversation, mirroring
/// router.ts:resolveConversationBillingTarget / resolveConversationSubjectId.
/// Group / temporary_group / crew conversations bill against the
/// conversation's immutable `responsible_subject_id`; everything else
/// (1v1, system) bills against the initiating user's own wallet (keyed by
/// userId). The WalletDO is keyed per subject via env.WALLET.idFromName.
///
/// Returns null only when there's no resolvable owner at all — in that
/// case the caller skips gate + debit ("can't attribute → don't bill")
/// rather than guessing.
export interface SandboxBillingTarget {
  /// 付钱的主体 —— **总是 subjects.id**(群责任主体,或个人的 user_account subject)。
  subjectId: string;
  /// 'subject' = 群责任主体(走 settleGroupSpend 分账);'user' = 个人钱包直扣。
  /// 别再用 "subjectId !== userId" 反推群/个人:键统一到 subjects.id 后那个判断恒真。
  kind: 'subject' | 'user';
}

export async function resolveSandboxBillingSubjectId(
  supa: SupabaseClient,
  conversationId: string,
  fallbackUserId: string | null,
): Promise<SandboxBillingTarget | null> {
  const { data } = await supa
    .from('conversations')
    .select('conversation_type, responsible_subject_id')
    .eq('id', conversationId)
    .maybeSingle();
  const row = data as
    | { conversation_type?: string; responsible_subject_id?: string | null }
    | null;
  const convType = row?.conversation_type;

  if (
    convType === 'group' ||
    convType === 'temporary_group' ||
    convType === 'crew'
  ) {
    // Group-family conversations: the responsible subject owns the wallet.
    // For real groups the column lives on `conversations`; for
    // temporary_group / crew it lives on temporary_group_meta (matching
    // router.ts). Prefer the conversations column, fall back to meta.
    const fromConv = row?.responsible_subject_id;
    if (typeof fromConv === 'string' && fromConv.length > 0) {
      return { subjectId: fromConv, kind: 'subject' };
    }

    const { data: meta } = await supa
      .from('temporary_group_meta')
      .select('responsible_subject_id')
      .eq('conversation_id', conversationId)
      .maybeSingle();
    const fromMeta = meta?.responsible_subject_id;
    if (typeof fromMeta === 'string' && fromMeta.length > 0) {
      return { subjectId: fromMeta, kind: 'subject' };
    }
    // Group-family conv with no responsible subject set: can't attribute.
    return resolvePersonalSubject(supa, fallbackUserId);
  }

  // 1v1 / system / unknown: bill the initiating user's own wallet.
  return resolvePersonalSubject(supa, fallbackUserId);
}

/// 个人钱包键 = 该用户的 user_account subject id(**不是** auth user id):
/// 入账被 pnc_ledger 外键钉死在 subjects.id,用 user id 会落到另一个空 DO。
/// 见 billing/subject-key.ts。解析不到就抛,由调用方 fail-open + 记日志。
async function resolvePersonalSubject(
  supa: SupabaseClient,
  userId: string | null,
): Promise<SandboxBillingTarget | null> {
  if (!userId || userId.length === 0) return null;
  return { subjectId: await resolveUserWalletSubjectId(supa, userId), kind: 'user' };
}

/// Run Python in this conversation's sandbox. State does NOT persist
/// across calls (each runCode invocation is its own interpreter session,
/// matching the model-facing tool description). Side effects on the
/// container filesystem do persist for the life of the sandbox.
///
/// Billing P2 (Phase F): when `meter.userId` is given the run is gated
/// and metered against the conversation's billing subject's WalletDO:
///   - PRE-GATE: wallet.gate() before runCode; thresholdState 'exhausted'
///     → throw SandboxGateError (don't run code we can't charge for).
///   - POST-DEBIT: wall-clock seconds × SANDBOX_USD_PER_SECOND (placeholder
///     price) → usdToPncMicros → wallet.debit(category:'sandbox_runtime'),
///     idempotent via a per-run dedupeId. Fire-and-forget so a wallet blip
///     can't fail a successful execution.
/// The SDK's runCode result carries no timing field (verified against the
/// official Sandbox SDK docs), so wall-clock is the only available signal.
export async function runPython(
  env: Env,
  conversationId: string,
  code: string,
  opts: {
    timeoutMs?: number;
    meter?: {
      // The initiating user. Subject resolution (group vs user wallet)
      // happens inside via resolveSandboxBillingSubjectId.
      userId?: string | null;
    } | null;
  } = {},
): Promise<CodeRunResult> {
  // Resolve billing subject once up front (used by both gate and debit).
  let target: SandboxBillingTarget | null = null;
  if (opts.meter?.userId) {
    const supa = serviceClient(env);
    try {
      target = await resolveSandboxBillingSubjectId(
        supa,
        conversationId,
        opts.meter.userId,
      );
    } catch (err) {
      // Resolution failure must not silently bypass the gate; but it also
      // shouldn't hard-fail the tool on a transient DB blip. Log + skip
      // billing for this run (degrade to "can't attribute → don't bill")。
      // 报错级:宁可这一跑不计费,也不拿一个猜的键去 gate/扣。
      console.error('[sandbox] billing subject resolution failed', conversationId, opts.meter?.userId ?? null, err);
      target = null;
    }
  }
  const subjectId = target?.subjectId ?? null;

  // PRE-EXECUTION GATE. Only when we have a subject to charge.
  if (subjectId) {
    try {
      const gate = await wallet.gate(env, subjectId);
      if (gate.thresholdState === 'exhausted') {
        throw new SandboxGateError(
          '账户余额已用完，无法执行代码。请充值后再试。',
        );
      }
    } catch (err) {
      if (err instanceof SandboxGateError) throw err;
      // A WalletDO read failure shouldn't block a paying user from running
      // code (fail-open on the gate read, never on an explicit exhausted).
      console.warn('[sandbox] wallet gate read failed, allowing run', subjectId, err);
    }
  }

  const sandbox = getSandbox(env.Sandbox, conversationId, {
    sleepAfter: SANDBOX_SLEEP_AFTER,
  });
  const startedAt = Date.now();
  const result = await sandbox.runCode(code, {
    language: 'python',
    timeout: opts.timeoutMs ?? CODE_RUN_TIMEOUT_MS,
  });
  const elapsedSeconds = Math.max(0, (Date.now() - startedAt) / 1000);

  // POST-EXECUTION DEBIT. Charge wall-clock seconds at the placeholder
  // price. Fire-and-forget: a wallet blip must not fail a run that already
  // happened. dedupeId is unique per run so retries can't double-charge.
  if (subjectId && elapsedSeconds > 0) {
    const usd = elapsedSeconds * SANDBOX_USD_PER_SECOND;
    const pncMicros = usdToPncMicros(usd);
    if (pncMicros > 0) {
      const dedupeId = `sandbox:${conversationId}:${startedAt}`;
      const meta = {
        conversation_id: conversationId,
        elapsed_seconds: elapsedSeconds,
        usd_per_second: SANDBOX_USD_PER_SECOND,
        exit_code: result.error ? 1 : 0,
        // Don't log the code itself — sensitive. Only the shape.
        code_chars: code.length,
      };
      // 群会话(解析到责任 subject)走 settleGroupSpend(实缴池衰减 + 认缴成员
      // 个人钱包直扣);个人直扣其钱包。按解析结果的 kind 判断 —— 两侧键都是
      // subjects.id,不能再靠 "≠ userId" 反推。
      const isGroup = target?.kind === 'subject';
      const charge = isGroup
        ? settleGroupSpend({ env, supa: serviceClient(env), subjectId, spendMicros: pncMicros, category: 'sandbox_runtime', dedupeId, meta })
        : wallet.debit(env, subjectId, pncMicros, { category: 'sandbox_runtime', dedupeId, meta }).then(() => undefined);
      void charge.catch((err) => {
        console.warn('[sandbox] wallet charge failed', subjectId, dedupeId, err);
      });
    }
  }

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
