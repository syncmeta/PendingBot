import Link from 'next/link';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtDay, fmtMs, fmtNumber, fmtTokens, fmtUsd } from '@/lib/format';
import { CostChart, type DailyPoint } from './cost-chart';

// Default range: last 7 days (UTC). The view buckets by day at UTC,
// so picking a UTC anchor keeps off-by-one errors out of the timeline.
function defaultRange(): { start: string; end: string } {
  const now = new Date();
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const start = new Date(end);
  start.setUTCDate(start.getUTCDate() - 6);
  return { start: start.toISOString().slice(0, 10), end: end.toISOString().slice(0, 10) };
}

type SearchParams = { start?: string; end?: string };

export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  await requireAdmin();
  const params = await searchParams;
  const fallback = defaultRange();
  const start = params.start ?? fallback.start;
  const end = params.end ?? fallback.end;

  // The view's `day` is timestamptz; comparing to a YYYY-MM-DD string
  // works because PG casts it to date-at-midnight-UTC.
  const startBound = `${start}T00:00:00Z`;
  // end is inclusive: shift to next-day midnight UTC for the upper bound.
  const endDate = new Date(`${end}T00:00:00Z`);
  endDate.setUTCDate(endDate.getUTCDate() + 1);
  const endBound = endDate.toISOString();

  const supa = supabaseAdmin();

  // Fetch the full v_audit_daily slice for this range. Aggregations
  // happen in JS — for pre-launch volume that's fine; swap to a SQL
  // function or materialized rollup once row count groans.
  const { data: dailyRows, error } = await supa
    .from('v_audit_daily')
    .select(
      'day, user_id, provider_id, model_id, task_type, request_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, avg_latency_ms, error_count, fallback_count',
    )
    .gte('day', startBound)
    .lt('day', endBound);

  // Recent requests panel — independent slice, raw audit_log rows.
  const { data: recent } = await supa
    .from('audit_log')
    .select(
      'id, created_at, user_id, task_type, model_id, status, error_class, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, latency_ms',
    )
    .order('created_at', { ascending: false })
    .limit(50);

  const rows = dailyRows ?? [];

  // Summary roll-up across the whole range.
  const summary = rows.reduce(
    (acc, r) => {
      acc.requests += r.request_count ?? 0;
      acc.input_tokens += r.input_tokens ?? 0;
      acc.output_tokens += r.output_tokens ?? 0;
      acc.cache_read_tokens += r.cache_read_tokens ?? 0;
      acc.cache_write_tokens += r.cache_write_tokens ?? 0;
      acc.cost_usd += Number(r.cost_usd ?? 0);
      acc.errors += r.error_count ?? 0;
      acc.fallbacks += r.fallback_count ?? 0;
      if (r.avg_latency_ms != null) {
        acc.latency_sum += r.avg_latency_ms * (r.request_count ?? 0);
      }
      return acc;
    },
    {
      requests: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      cost_usd: 0,
      errors: 0,
      fallbacks: 0,
      latency_sum: 0,
    },
  );
  const avgLatency = summary.requests > 0 ? summary.latency_sum / summary.requests : null;
  const cacheHitRate =
    summary.input_tokens + summary.cache_read_tokens > 0
      ? summary.cache_read_tokens / (summary.input_tokens + summary.cache_read_tokens)
      : null;

  // Daily timeline for the chart.
  const byDay = new Map<string, DailyPoint>();
  for (const r of rows) {
    const day = fmtDay(r.day as unknown as string);
    const cur = byDay.get(day) ?? { day, cost_usd: 0, request_count: 0 };
    cur.cost_usd += Number(r.cost_usd ?? 0);
    cur.request_count += r.request_count ?? 0;
    byDay.set(day, cur);
  }
  const timeline = [...byDay.values()].sort((a, b) => a.day.localeCompare(b.day));

  // Top dimensions: by cost_usd descending, take 10.
  const topByDimension = (key: 'user_id' | 'task_type' | 'model_id' | 'provider_id') => {
    const m = new Map<string, { key: string; cost_usd: number; requests: number }>();
    for (const r of rows) {
      const k = (r[key] as string | null) ?? '(unknown)';
      const cur = m.get(k) ?? { key: k, cost_usd: 0, requests: 0 };
      cur.cost_usd += Number(r.cost_usd ?? 0);
      cur.requests += r.request_count ?? 0;
      m.set(k, cur);
    }
    return [...m.values()].sort((a, b) => b.cost_usd - a.cost_usd).slice(0, 10);
  };

  const topUsers = topByDimension('user_id');
  const topTasks = topByDimension('task_type');
  const topModels = topByDimension('model_id');

  // Resolve user_ids → display_name for the top-users table.
  const userIds = topUsers.map((u) => u.key).filter((k) => k !== '(unknown)');
  const { data: userRows } = userIds.length
    ? await supa.from('users').select('id, display_name, email').in('id', userIds)
    : { data: [] as { id: string; display_name: string; email: string | null }[] };
  const userMap = new Map((userRows ?? []).map((u) => [u.id, u]));

  return (
    <main className="container py-10 space-y-10">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Audit Explorer</h1>
          <p className="text-sm text-muted-foreground">
            按时间窗口看 token 用量、成本、错误率与 fallback。{' '}
            <Link href="/" className="underline">
              ← 返回
            </Link>
          </p>
        </div>
        <DateRangeForm start={start} end={end} />
      </header>

      {error && (
        <p className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          查询出错：{error.message}
        </p>
      )}

      <section className="grid grid-cols-2 gap-4 md:grid-cols-4 lg:grid-cols-7">
        <Stat label="请求数" value={fmtNumber(summary.requests)} />
        <Stat label="花费 (USD)" value={fmtUsd(summary.cost_usd)} accent />
        <Stat label="输入 tokens" value={fmtTokens(summary.input_tokens)} />
        <Stat label="输出 tokens" value={fmtTokens(summary.output_tokens)} />
        <Stat
          label="缓存命中率"
          value={cacheHitRate == null ? '—' : `${(cacheHitRate * 100).toFixed(1)}%`}
        />
        <Stat label="平均延迟" value={fmtMs(avgLatency)} />
        <Stat
          label="错误 / Fallback"
          value={`${fmtNumber(summary.errors)} / ${fmtNumber(summary.fallbacks)}`}
        />
      </section>

      <section className="rounded-lg border bg-card p-5">
        <h2 className="text-sm font-medium">每日花费</h2>
        <div className="mt-4">
          {timeline.length > 0 ? (
            <CostChart data={timeline} />
          ) : (
            <p className="py-12 text-center text-sm text-muted-foreground">
              这段时间没有 audit 记录
            </p>
          )}
        </div>
      </section>

      <section className="grid gap-4 md:grid-cols-3">
        <TopTable
          title="花费 Top 用户"
          rows={topUsers.map((u) => ({
            label:
              u.key === '(unknown)'
                ? '(无 user)'
                : (userMap.get(u.key)?.display_name ?? u.key.slice(0, 8)),
            sub: u.key === '(unknown)' ? undefined : userMap.get(u.key)?.email ?? undefined,
            cost: u.cost_usd,
            requests: u.requests,
          }))}
        />
        <TopTable
          title="花费 Top task_type"
          rows={topTasks.map((t) => ({
            label: t.key,
            cost: t.cost_usd,
            requests: t.requests,
          }))}
        />
        <TopTable
          title="花费 Top model"
          rows={topModels.map((m) => ({
            label: m.key,
            cost: m.cost_usd,
            requests: m.requests,
          }))}
        />
      </section>

      <section>
        <h2 className="text-sm font-medium">最近 50 条请求</h2>
        <div className="mt-3 overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <Th>时间</Th>
                <Th>task</Th>
                <Th>model</Th>
                <Th>状态</Th>
                <Th className="text-right">in</Th>
                <Th className="text-right">out</Th>
                <Th className="text-right">cache↓</Th>
                <Th className="text-right">cost</Th>
                <Th className="text-right">延迟</Th>
              </tr>
            </thead>
            <tbody>
              {(recent ?? []).map((r) => (
                <tr key={r.id} className="border-b last:border-0">
                  <Td>{new Date(r.created_at).toISOString().replace('T', ' ').slice(0, 19)}</Td>
                  <Td>{r.task_type}</Td>
                  <Td className="font-mono text-xs">{r.model_id}</Td>
                  <Td>
                    {r.status === 'error' ? (
                      <span className="text-destructive">{r.error_class ?? 'error'}</span>
                    ) : (
                      (r.status ?? 'ok')
                    )}
                  </Td>
                  <Td className="text-right">{fmtTokens(r.input_tokens)}</Td>
                  <Td className="text-right">{fmtTokens(r.output_tokens)}</Td>
                  <Td className="text-right">{fmtTokens(r.cache_read_tokens)}</Td>
                  <Td className="text-right">{fmtUsd(r.cost_usd)}</Td>
                  <Td className="text-right">{fmtMs(r.latency_ms)}</Td>
                </tr>
              ))}
              {(recent ?? []).length === 0 && (
                <tr>
                  <td colSpan={9} className="px-4 py-8 text-center text-muted-foreground">
                    暂无 audit 记录
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}

function Stat({
  label,
  value,
  accent,
}: {
  label: string;
  value: string;
  accent?: boolean;
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div
        className={
          accent
            ? 'mt-1 text-lg font-semibold tabular-nums'
            : 'mt-1 text-lg font-medium tabular-nums'
        }
      >
        {value}
      </div>
    </div>
  );
}

function TopTable({
  title,
  rows,
}: {
  title: string;
  rows: { label: string; sub?: string; cost: number; requests: number }[];
}) {
  return (
    <div className="rounded-lg border bg-card">
      <h3 className="border-b px-4 py-2 text-sm font-medium">{title}</h3>
      {rows.length === 0 ? (
        <p className="px-4 py-6 text-sm text-muted-foreground">无数据</p>
      ) : (
        <table className="w-full text-sm">
          <tbody>
            {rows.map((r) => (
              <tr key={r.label} className="border-b last:border-0">
                <td className="px-4 py-2">
                  <div className="font-medium">{r.label}</div>
                  {r.sub && <div className="text-xs text-muted-foreground">{r.sub}</div>}
                </td>
                <td className="px-4 py-2 text-right tabular-nums">{fmtUsd(r.cost)}</td>
                <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                  {fmtNumber(r.requests)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function Th({ children, className }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 font-medium ${className ?? ''}`}>{children}</th>;
}
function Td({ children, className }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-2 ${className ?? ''}`}>{children}</td>;
}

function DateRangeForm({ start, end }: { start: string; end: string }) {
  return (
    <form className="flex items-center gap-2 text-sm">
      <input
        type="date"
        name="start"
        defaultValue={start}
        className="rounded-md border border-input bg-background px-2 py-1"
      />
      <span className="text-muted-foreground">→</span>
      <input
        type="date"
        name="end"
        defaultValue={end}
        className="rounded-md border border-input bg-background px-2 py-1"
      />
      <button
        type="submit"
        className="rounded-md border border-input bg-background px-3 py-1 hover:bg-accent"
      >
        查询
      </button>
    </form>
  );
}
