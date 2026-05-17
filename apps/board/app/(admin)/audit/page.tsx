import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtMs, fmtTokens, fmtUsd } from '@/lib/format';

// Full audit_log browser — one row per LLM / voice / tool turn across
// every user. This is the detailed call log; the iOS wallet only shows
// a summary now. Filter to one user with ?user_id=, narrow by task with
// ?task_type=, page size via ?limit=. Linked from the user detail page
// ("完整 audit →") and the test-logs page.

type SearchParams = {
  user_id?: string;
  task_type?: string;
  limit?: string;
};

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 2000;

type ToolCall = {
  id: string;
  audit_log_id: string;
  kind: string;
  provider: string;
  target: string;
  status: string;
  error_class: string | null;
  latency_ms: number | null;
  result_count: number | null;
  cost_usd: number;
};

const BILLING_PALETTE: Record<string, string> = {
  billed: 'bg-emerald-100 text-emerald-700',
  unbilled: 'bg-amber-100 text-amber-800',
  pending: 'bg-blue-100 text-blue-700',
  skipped: 'bg-slate-100 text-slate-600',
  free: 'bg-slate-100 text-slate-600',
};

function billingBadge(status: string | null): string {
  return BILLING_PALETTE[status ?? ''] ?? 'bg-muted text-muted-foreground';
}

export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const sp = await searchParams;
  const userId = (sp.user_id ?? '').trim();
  const taskType = (sp.task_type ?? '').trim();
  const limit = Math.min(
    MAX_LIMIT,
    Math.max(1, Number.parseInt(sp.limit ?? '', 10) || DEFAULT_LIMIT),
  );

  const supa = supabaseAdmin();

  let query = supa
    .from('audit_log')
    .select(
      'id, created_at, user_id, task_type, model_id, status, error_class, input_tokens, output_tokens, cache_read_tokens, audio_input_tokens, audio_output_tokens, cost_usd, tool_cost_usd, cost_credits, billing_status, latency_ms, conversation_id, metadata',
    )
    .order('created_at', { ascending: false })
    .limit(limit);
  if (userId) query = query.eq('user_id', userId);
  if (taskType) query = query.eq('task_type', taskType);
  const { data: rows } = await query;
  const turns = rows ?? [];

  // Fan out the per-turn web-tool calls.
  const turnIds = turns.map((t) => t.id);
  const { data: toolCalls } = turnIds.length
    ? await supa
        .from('audit_web_tool_calls')
        .select(
          'id, audit_log_id, kind, provider, target, status, error_class, latency_ms, result_count, cost_usd',
        )
        .in('audit_log_id', turnIds)
    : { data: [] as ToolCall[] };
  const toolCallsByTurn = new Map<string, ToolCall[]>();
  for (const t of (toolCalls ?? []) as ToolCall[]) {
    const arr = toolCallsByTurn.get(t.audit_log_id) ?? [];
    arr.push(t);
    toolCallsByTurn.set(t.audit_log_id, arr);
  }

  // Resolve user display names (skip when already filtered to one user).
  const userIds = [
    ...new Set(turns.map((t) => t.user_id).filter((x): x is string => !!x)),
  ];
  const { data: users } = userIds.length
    ? await supa.from('users').select('id, display_name, email').in('id', userIds)
    : { data: [] as { id: string; display_name: string; email: string | null }[] };
  const userMap = new Map((users ?? []).map((u) => [u.id, u]));
  const filteredUser = userId ? userMap.get(userId) : null;

  const totalUsd = turns.reduce(
    (s, t) => s + Number(t.cost_usd ?? 0) + Number(t.tool_cost_usd ?? 0),
    0,
  );
  const totalPnd = turns.reduce((s, t) => s + Number(t.cost_credits ?? 0), 0);
  const colSpan = userId ? 9 : 10;

  return (
    <main className="container py-10 space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Audit</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            每一次 LLM / 语音 / 工具调用的明细。
            {filteredUser && (
              <span className="ml-1">
                当前筛选：
                <Link href={`/users/${userId}`} className="underline">
                  {filteredUser.display_name || filteredUser.email || userId}
                </Link>
              </span>
            )}
          </p>
        </div>
        <form className="flex flex-wrap items-center gap-2 text-sm">
          <input
            type="text"
            name="user_id"
            placeholder="user_id"
            defaultValue={userId}
            className="w-64 rounded-md border border-input bg-background px-2 py-1 font-mono text-xs"
          />
          <input
            type="text"
            name="task_type"
            placeholder="task_type"
            defaultValue={taskType}
            className="w-36 rounded-md border border-input bg-background px-2 py-1"
          />
          <input
            type="number"
            name="limit"
            min={1}
            max={MAX_LIMIT}
            defaultValue={limit}
            className="w-20 rounded-md border border-input bg-background px-2 py-1"
          />
          <button
            type="submit"
            className="rounded-md border border-input px-3 py-1 hover:bg-accent"
          >
            筛选
          </button>
        </form>
      </header>

      <p className="text-xs text-muted-foreground">
        显示最近 {turns.length} 条 · 合计 {fmtUsd(totalUsd)} ·{' '}
        {totalPnd.toFixed(0)} ∂
      </p>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-3 py-2 font-medium">时间</th>
              {!userId && <th className="px-3 py-2 font-medium">用户</th>}
              <th className="px-3 py-2 font-medium">task</th>
              <th className="px-3 py-2 font-medium">model</th>
              <th className="px-3 py-2 font-medium">status</th>
              <th className="px-3 py-2 font-medium text-right">in / out / cache</th>
              <th className="px-3 py-2 font-medium text-right">llm / tool / total</th>
              <th className="px-3 py-2 font-medium text-right">∂</th>
              <th className="px-3 py-2 font-medium text-right">延迟</th>
              <th className="px-3 py-2 font-medium">明细</th>
            </tr>
          </thead>
          <tbody>
            {turns.map((t) => {
              const tcs = toolCallsByTurn.get(t.id) ?? [];
              const total =
                Number(t.cost_usd ?? 0) + Number(t.tool_cost_usd ?? 0);
              const user = t.user_id ? userMap.get(t.user_id) : null;
              const audio =
                Number(t.audio_input_tokens ?? 0) +
                Number(t.audio_output_tokens ?? 0);
              const botId =
                t.metadata && typeof t.metadata === 'object'
                  ? (t.metadata as Record<string, unknown>).bot_id
                  : null;
              return (
                <tr key={t.id} className="border-b align-top last:border-0">
                  <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">
                    {new Date(t.created_at).toISOString().replace('T', ' ').slice(0, 19)}
                    {t.conversation_id && (
                      <div className="text-[10px] text-muted-foreground">
                        conv {t.conversation_id.slice(0, 8)}
                      </div>
                    )}
                  </td>
                  {!userId && (
                    <td className="px-3 py-2 text-xs">
                      {user ? (
                        <Link
                          href={`/audit?user_id=${t.user_id}`}
                          className="underline"
                        >
                          {user.display_name || user.email || t.user_id!.slice(0, 8)}
                        </Link>
                      ) : (
                        <span className="text-muted-foreground">—</span>
                      )}
                    </td>
                  )}
                  <td className="px-3 py-2 text-xs">
                    {t.task_type}
                    {typeof botId === 'string' && (
                      <div className="text-[10px] text-muted-foreground">
                        bot {botId.slice(0, 8)}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 font-mono text-xs">{t.model_id}</td>
                  <td className="px-3 py-2 text-xs">
                    {t.status === 'error' ? (
                      <span className="font-medium text-destructive">
                        {t.error_class ?? 'error'}
                      </span>
                    ) : (
                      <span className="text-emerald-700">{t.status ?? 'ok'}</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                    {fmtTokens(t.input_tokens)} / {fmtTokens(t.output_tokens)} /{' '}
                    <span className="text-muted-foreground">
                      {fmtTokens(t.cache_read_tokens)}
                    </span>
                    {audio > 0 && (
                      <div className="text-[10px] text-blue-700">
                        audio {fmtTokens(audio)}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                    {fmtUsd(t.cost_usd)} /{' '}
                    <span className="text-muted-foreground">
                      {fmtUsd(t.tool_cost_usd)}
                    </span>{' '}
                    / <span className="font-medium">{fmtUsd(total)}</span>
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                    {Number(t.cost_credits ?? 0).toFixed(0)}
                    <div>
                      <span
                        className={`rounded px-1 text-[10px] ${billingBadge(t.billing_status)}`}
                      >
                        {t.billing_status ?? '—'}
                      </span>
                    </div>
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                    {fmtMs(t.latency_ms)}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    {tcs.length === 0 ? (
                      <span className="text-muted-foreground">—</span>
                    ) : (
                      <details>
                        <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
                          {tcs.length} tool
                        </summary>
                        <ul className="mt-2 space-y-1">
                          {tcs.map((tc) => (
                            <li
                              key={tc.id}
                              className="rounded border border-border/60 bg-muted/40 p-2 text-[11px]"
                            >
                              <div className="flex items-center justify-between gap-2">
                                <span className="font-mono">
                                  <span className="text-blue-700">{tc.kind}</span> @{' '}
                                  {tc.provider}
                                </span>
                                <span className="tabular-nums text-muted-foreground">
                                  {fmtMs(tc.latency_ms)} · {fmtUsd(tc.cost_usd)}
                                </span>
                              </div>
                              <div className="mt-1 break-all font-mono text-[10px] text-muted-foreground">
                                {tc.target}
                              </div>
                              {tc.status === 'error' ? (
                                <p className="mt-1 text-destructive">
                                  error · {tc.error_class ?? '—'}
                                </p>
                              ) : (
                                tc.result_count != null && (
                                  <p className="mt-1 text-muted-foreground">
                                    {tc.result_count} results
                                  </p>
                                )
                              )}
                            </li>
                          ))}
                        </ul>
                      </details>
                    )}
                  </td>
                </tr>
              );
            })}
            {turns.length === 0 && (
              <tr>
                <td
                  colSpan={colSpan}
                  className="px-3 py-8 text-center text-muted-foreground"
                >
                  没有匹配的调用记录
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </main>
  );
}
