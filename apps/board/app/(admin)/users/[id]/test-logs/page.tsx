import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';

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

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xs text-muted-foreground">
            <Link href={`/users/${id}`} className="underline">
              ← {user.display_name || user.email || id}
            </Link>
          </p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight">详细日志（test_account_log）</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            edge worker 给标了 is_test_account 的用户每条 /v1 请求都会落一行。
            {!user.is_test_account && (
              <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-800">
                当前未启用 — 新请求不会再写入
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
    </main>
  );
}
