import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtMs, fmtTokens, fmtUsd } from '@/lib/format';

// Verbose request log for is_test_account users. Populated by the
// edge worker's testAccountLogger middleware (see
// apps/edge/src/lib/test-account-log.ts) — one row per /v1 request
// plus any logTestEvent() calls from route code.

type SearchParams = { limit?: string; kind?: string };

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 2000;

const KIND_PALETTE: Record<string, string> = {
  http_request: 'bg-slate-100 text-slate-700',
  error: 'bg-rose-100 text-rose-700',
  llm_call: 'bg-blue-100 text-blue-700',
  push: 'bg-emerald-100 text-emerald-700',
};

function kindBadge(kind: string): string {
  return KIND_PALETTE[kind] ?? 'bg-muted text-muted-foreground';
}

function statusClass(status: number | null): string {
  if (status === null) return 'text-muted-foreground';
  if (status >= 500) return 'text-destructive font-medium';
  if (status >= 400) return 'text-amber-700 font-medium';
  if (status >= 300) return 'text-blue-700';
  return 'text-emerald-700';
}

type ToolCall = {
  id: string;
  audit_log_id: string;
  created_at: string;
  kind: string;
  provider: string;
  target: string;
  status: string;
  error_class: string | null;
  latency_ms: number | null;
  result_count: number | null;
  cost_usd: number;
};

export default async function UserTestLogsPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<SearchParams>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const limit = Math.min(
    MAX_LIMIT,
    Math.max(1, Number.parseInt(sp.limit ?? '', 10) || DEFAULT_LIMIT),
  );
  const kindFilter = (sp.kind ?? '').trim();

  const supa = supabaseAdmin();

  const { data: user } = await supa
    .from('users')
    .select('id, display_name, email, is_test_account')
    .eq('id', id)
    .maybeSingle();
  if (!user) notFound();

  let query = supa
    .from('test_account_log')
    .select('id, occurred_at, kind, route, method, status, latency_ms, request_id, note, payload')
    .eq('user_id', id)
    .order('occurred_at', { ascending: false })
    .limit(limit);
  if (kindFilter) query = query.eq('kind', kindFilter);
  const { data: rows } = await query;

  // Tiny per-kind tally so the operator can eyeball "is this user
  // mostly hitting messages?" without scrolling the whole list.
  const tally = new Map<string, number>();
  for (const r of rows ?? []) tally.set(r.kind, (tally.get(r.kind) ?? 0) + 1);

  // Recent LLM turns (audit_log) for this user, with the per-web-tool-call
  // breakdown fanned out, scoped to one user so the test-account log page
  // is the single place to look when debugging a tester's session.
  const RECENT_TURNS = 50;
  const { data: turns } = await supa
    .from('audit_log')
    .select(
      'id, created_at, task_type, model_id, status, error_class, input_tokens, output_tokens, cache_read_tokens, cost_usd, tool_cost_usd, latency_ms, conversation_id, cost_credits, billing_status',
    )
    .eq('user_id', id)
    .order('created_at', { ascending: false })
    .limit(RECENT_TURNS);

  const turnIds = (turns ?? []).map((t) => t.id);
  const [{ data: toolCalls }] = await Promise.all([
    turnIds.length
      ? supa
          .from('audit_web_tool_calls')
          .select('id, audit_log_id, created_at, kind, provider, target, status, error_class, latency_ms, result_count, cost_usd')
          .in('audit_log_id', turnIds)
          .order('created_at', { ascending: true })
      : Promise.resolve({ data: [] as ToolCall[] }),
  ]);

  const toolCallsByTurn = new Map<string, ToolCall[]>();
  for (const t of (toolCalls ?? []) as ToolCall[]) {
    const arr = toolCallsByTurn.get(t.audit_log_id) ?? [];
    arr.push(t);
    toolCallsByTurn.set(t.audit_log_id, arr);
  }

  const turnsTotalCost = (turns ?? []).reduce(
    (s, t) => s + Number(t.cost_usd ?? 0) + Number(t.tool_cost_usd ?? 0),
    0,
  );
  const turnsTotalCredits = (turns ?? []).reduce(
    (s, t) => s + Number(t.cost_credits ?? 0),
    0,
  );

  return (
    <main className="container py-10 space-y-8">
      <header className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xs text-muted-foreground">
            <Link href={`/users/${id}`} className="underline">
              ← {user.display_name || user.email || id}
            </Link>
          </p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight">详细日志</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            上半部分是该用户最近的 LLM / 工具调用（所有用户都在记，不依赖 is_test_account），
            下半部分是 edge worker 给标了 is_test_account 的用户每条 /v1 请求落的一行。
            {!user.is_test_account && (
              <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-800">
                test 标记当前关闭 — 下方 http 日志不会再写入
              </span>
            )}
          </p>
        </div>
        <form className="flex items-center gap-2 text-sm">
          <select
            name="kind"
            defaultValue={kindFilter}
            className="rounded-md border border-input bg-background px-2 py-1"
          >
            <option value="">全部 kind</option>
            <option value="http_request">http_request</option>
            <option value="error">error</option>
            <option value="llm_call">llm_call</option>
            <option value="push">push</option>
          </select>
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
            刷新
          </button>
        </form>
      </header>

      <section className="space-y-3">
        <div className="flex items-baseline justify-between">
          <h2 className="text-sm font-medium">
            最近 {RECENT_TURNS} 次 LLM / 工具调用
          </h2>
          <p className="text-xs text-muted-foreground">
            合计 {fmtUsd(turnsTotalCost)} ·{' '}
            {turnsTotalCredits.toFixed(2)} ∂{' '}
            <Link href={`/audit?user_id=${id}`} className="ml-2 underline">
              完整 audit →
            </Link>
          </p>
        </div>
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-3 py-2 font-medium">时间</th>
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
              {(turns ?? []).map((t) => {
                const tcs = toolCallsByTurn.get(t.id) ?? [];
                const total =
                  Number(t.cost_usd ?? 0) + Number(t.tool_cost_usd ?? 0);
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
                    <td className="px-3 py-2 text-xs">{t.task_type}</td>
                    <td className="px-3 py-2 font-mono text-xs">
                      {t.model_id}
                    </td>
                    <td className="px-3 py-2 text-xs">
                      {t.status === 'error' ? (
                        <span className="text-destructive font-medium">
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
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                      {fmtUsd(t.cost_usd)} /{' '}
                      <span className="text-muted-foreground">
                        {fmtUsd(t.tool_cost_usd)}
                      </span>{' '}
                      / <span className="font-medium">{fmtUsd(total)}</span>
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                      {Number(t.cost_credits ?? 0).toFixed(2)}
                      {t.billing_status === 'unbilled' && (
                        <span
                          className="ml-1 rounded bg-amber-100 px-1 text-[10px] text-amber-800"
                          title="尚未扣费（unbilled）"
                        >
                          unbilled
                        </span>
                      )}
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
                          <div className="mt-2 space-y-3">
                            {tcs.length > 0 && (
                              <div>
                                <div className="mb-1 text-[10px] uppercase text-muted-foreground">
                                  web tool calls
                                </div>
                                <ul className="space-y-1">
                                  {tcs.map((tc) => (
                                    <li
                                      key={tc.id}
                                      className="rounded border border-border/60 bg-muted/40 p-2 text-[11px]"
                                    >
                                      <div className="flex items-center justify-between gap-2">
                                        <span className="font-mono">
                                          <span className="text-blue-700">{tc.kind}</span>{' '}
                                          @ {tc.provider}
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
                              </div>
                            )}
                          </div>
                        </details>
                      )}
                    </td>
                  </tr>
                );
              })}
              {(turns ?? []).length === 0 && (
                <tr>
                  <td colSpan={9} className="px-3 py-8 text-center text-muted-foreground">
                    该用户还没有 LLM 调用记录
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">
          HTTP 请求日志（test_account_log）
        </h2>

      {tally.size > 0 && (
        <div className="flex flex-wrap items-center gap-2 text-xs">
          {[...tally.entries()]
            .sort((a, b) => b[1] - a[1])
            .map(([kind, count]) => (
              <span
                key={kind}
                className={`rounded-full px-2 py-0.5 ${kindBadge(kind)}`}
              >
                {kind} · {count}
              </span>
            ))}
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-3 py-2 font-medium">时间</th>
              <th className="px-3 py-2 font-medium">kind</th>
              <th className="px-3 py-2 font-medium">method · route</th>
              <th className="px-3 py-2 font-medium text-right">status</th>
              <th className="px-3 py-2 font-medium text-right">latency</th>
              <th className="px-3 py-2 font-medium">详情</th>
            </tr>
          </thead>
          <tbody>
            {(rows ?? []).map((r) => {
              const payloadStr =
                r.payload && typeof r.payload === 'object'
                  ? JSON.stringify(r.payload, null, 2)
                  : String(r.payload ?? '');
              const isEmptyPayload = payloadStr === '{}' || payloadStr === '';
              return (
                <tr key={r.id} className="border-b align-top last:border-0">
                  <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">
                    {new Date(r.occurred_at).toISOString().replace('T', ' ').slice(11, 19)}
                    <div className="text-[10px] text-muted-foreground">
                      {new Date(r.occurred_at).toISOString().slice(0, 10)}
                    </div>
                  </td>
                  <td className="px-3 py-2">
                    <span className={`rounded-full px-2 py-0.5 text-xs ${kindBadge(r.kind)}`}>
                      {r.kind}
                    </span>
                  </td>
                  <td className="px-3 py-2 font-mono text-xs">
                    {r.method && (
                      <span className="mr-1 text-muted-foreground">{r.method}</span>
                    )}
                    <span>{r.route ?? '—'}</span>
                    {r.request_id && (
                      <div className="text-[10px] text-muted-foreground">
                        cf-ray {r.request_id}
                      </div>
                    )}
                  </td>
                  <td
                    className={`px-3 py-2 text-right font-mono text-xs tabular-nums ${statusClass(
                      r.status,
                    )}`}
                  >
                    {r.status ?? '—'}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs tabular-nums">
                    {r.latency_ms != null ? `${r.latency_ms} ms` : '—'}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    {r.note && (
                      <p className="mb-1 whitespace-pre-wrap font-mono text-rose-700">
                        {r.note}
                      </p>
                    )}
                    {!isEmptyPayload && (
                      <details>
                        <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
                          payload
                        </summary>
                        <pre className="mt-1 max-h-64 overflow-auto rounded bg-muted p-2 text-[11px] leading-snug">
                          {payloadStr}
                        </pre>
                      </details>
                    )}
                  </td>
                </tr>
              );
            })}
            {(rows ?? []).length === 0 && (
              <tr>
                <td colSpan={6} className="px-3 py-8 text-center text-muted-foreground">
                  还没有日志。把开关打开后让用户去客户端操作几下，再回来刷新。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

        <p className="text-xs text-muted-foreground">
          显示最近 {limit} 条。超过这个数说明该用户日志已经积了不少，需要的话直接
          delete from test_account_log where user_id = '{id}' 清掉旧的（FK on
          delete cascade 会随用户删除清空，不必担心遗留）。
        </p>
      </section>
    </main>
  );
}
