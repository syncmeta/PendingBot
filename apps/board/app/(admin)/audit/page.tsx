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

type SearchParams = {
  start?: string;
  end?: string;
  user_id?: string;
  task_type?: string;
  provider_id?: string;
  model_id?: string;
};

export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const fallback = defaultRange();
  const start = params.start ?? fallback.start;
  const end = params.end ?? fallback.end;
  const filterUserId = params.user_id?.trim() || null;
  const filterTaskType = params.task_type?.trim() || null;
  const filterProviderId = params.provider_id?.trim() || null;
  const filterModelId = params.model_id?.trim() || null;

  // The view's `day` is timestamptz; comparing to a YYYY-MM-DD string
  // works because PG casts it to date-at-midnight-UTC.
  const startBound = `${start}T00:00:00Z`;
  // end is inclusive: shift to next-day midnight UTC for the upper bound.
  const endDate = new Date(`${end}T00:00:00Z`);
  endDate.setUTCDate(endDate.getUTCDate() + 1);
  const endBound = endDate.toISOString();

  const supa = supabaseAdmin();

  // Pull dropdown option lists in parallel with the main query — small
  // tables, cheap, lets the filter UI render without re-fetching.
  const [optionsR] = await Promise.all([
    Promise.all([
      supa.from('llm_providers').select('id, slug, display_name').order('priority'),
      supa.from('llm_models').select('id, slug, display_name').order('slug'),
    ]),
  ]);
  const providerOptions = optionsR[0].data ?? [];
  const modelOptions = optionsR[1].data ?? [];

  // Fetch the full v_audit_daily slice for this range. Aggregations
  // happen in JS — for pre-launch volume that's fine; swap to a SQL
  // function or materialized rollup once row count groans.
  let dailyQ = supa
    .from('v_audit_daily')
    .select(
      'day, user_id, provider_id, model_id, task_type, request_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, tool_cost_usd, provider_cost_usd, avg_latency_ms, error_count, fallback_count',
    )
    .gte('day', startBound)
    .lt('day', endBound);
  if (filterUserId) dailyQ = dailyQ.eq('user_id', filterUserId);
  if (filterTaskType) dailyQ = dailyQ.eq('task_type', filterTaskType);
  if (filterProviderId) dailyQ = dailyQ.eq('provider_id', filterProviderId);
  if (filterModelId) dailyQ = dailyQ.eq('model_id', filterModelId);
  const { data: dailyRows, error } = await dailyQ;

  // Recent requests panel — independent slice, raw audit_log rows.
  // est_input_tokens / est_output_tokens are local heuristic estimates
  // written by edge alongside the provider-reported counts; the panel
  // surfaces both so a divergent ratio (e.g. provider 1.4× the local
  // estimate) shows up as a billing-honesty smell test.
  let recentQ = supa
    .from('audit_log')
    .select(
      'id, created_at, user_id, task_type, model_id, status, error_class, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, est_input_tokens, est_output_tokens, cost_usd, tool_cost_usd, provider_cost_usd, reported_provider, cost_details, prompt_tokens_details, completion_tokens_details, latency_ms',
    )
    .order('created_at', { ascending: false })
    .limit(50);
  if (filterUserId) recentQ = recentQ.eq('user_id', filterUserId);
  if (filterTaskType) recentQ = recentQ.eq('task_type', filterTaskType);
  if (filterProviderId) recentQ = recentQ.eq('provider_id', filterProviderId);
  if (filterModelId) recentQ = recentQ.eq('model_id', filterModelId);
  const { data: recent } = await recentQ;

  let detailQ = supa
    .from('audit_log')
    .select(
      'reported_provider, cost_details, prompt_tokens_details, completion_tokens_details',
    )
    .gte('created_at', startBound)
    .lt('created_at', endBound);
  if (filterUserId) detailQ = detailQ.eq('user_id', filterUserId);
  if (filterTaskType) detailQ = detailQ.eq('task_type', filterTaskType);
  if (filterProviderId) detailQ = detailQ.eq('provider_id', filterProviderId);
  if (filterModelId) detailQ = detailQ.eq('model_id', filterModelId);
  const { data: detailRows } = await detailQ;

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
      acc.tool_cost_usd += Number(r.tool_cost_usd ?? 0);
      acc.provider_cost_usd += Number(r.provider_cost_usd ?? 0);
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
      tool_cost_usd: 0,
      provider_cost_usd: 0,
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
    cur.cost_usd += Number(r.cost_usd ?? 0) + Number(r.tool_cost_usd ?? 0);
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
      cur.cost_usd += Number(r.cost_usd ?? 0) + Number(r.tool_cost_usd ?? 0);
      cur.requests += r.request_count ?? 0;
      m.set(k, cur);
    }
    return [...m.values()].sort((a, b) => b.cost_usd - a.cost_usd).slice(0, 10);
  };

  const topUsers = topByDimension('user_id');
  const topTasks = topByDimension('task_type');
  const topModels = topByDimension('model_id');
  const providerCounts = topCounts((detailRows ?? []).map((r) => r.reported_provider));
  const costDetailStats = aggregateJsonNumbers((detailRows ?? []).map((r) => r.cost_details));
  const promptDetailStats = aggregateJsonNumbers(
    (detailRows ?? []).map((r) => r.prompt_tokens_details),
  );
  const completionDetailStats = aggregateJsonNumbers(
    (detailRows ?? []).map((r) => r.completion_tokens_details),
  );

  // Resolve user_ids → display_name for the top-users table.
  const userIds = topUsers.map((u) => u.key).filter((k) => k !== '(unknown)');
  const { data: userRows } = userIds.length
    ? await supa.from('users').select('id, display_name, email').in('id', userIds)
    : { data: [] as { id: string; display_name: string; email: string | null }[] };
  const userMap = new Map((userRows ?? []).map((u) => [u.id, u]));
  const totalCostUsd = summary.cost_usd + summary.tool_cost_usd;

  return (
    <main className="container py-10 space-y-10">
      <header className="space-y-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Audit Explorer</h1>
          <p className="text-sm text-muted-foreground">
            按时间窗口和维度过滤看 token 用量、成本、错误率与 fallback。
          </p>
        </div>
        <FilterForm
          start={start}
          end={end}
          userId={filterUserId ?? ''}
          taskType={filterTaskType ?? ''}
          providerId={filterProviderId ?? ''}
          modelId={filterModelId ?? ''}
          providers={providerOptions}
          models={modelOptions}
        />
      </header>

      {error && (
        <p className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          查询出错：{error.message}
        </p>
      )}

      <section className="grid grid-cols-2 gap-4 md:grid-cols-5 lg:grid-cols-10">
        <Stat label="请求数" value={fmtNumber(summary.requests)} />
        <Stat label="总花费 (USD)" value={fmtUsd(totalCostUsd)} accent />
        <Stat label="LLM 计费 (本地)" value={fmtUsd(summary.cost_usd)} />
        <Stat label="Web Tool 花费" value={fmtUsd(summary.tool_cost_usd)} />
        <Stat label="厂商上报价" value={fmtUsd(summary.provider_cost_usd)} />
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

      <section className="grid gap-4 md:grid-cols-4">
        <DetailTable
          title="厂商返回 provider"
          rows={providerCounts}
          valueKind="count"
        />
        <DetailTable title="cost_details" rows={costDetailStats} />
        <DetailTable title="prompt_tokens_details" rows={promptDetailStats} valueKind="tokens" />
        <DetailTable
          title="completion_tokens_details"
          rows={completionDetailStats}
          valueKind="tokens"
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
                <Th className="text-right" title="本地启发式估算 (token-estimate.ts)">
                  in est
                </Th>
                <Th className="text-right" title="provider / local — 偏离 1.0 越多越可疑">
                  Δin
                </Th>
                <Th className="text-right">out</Th>
                <Th className="text-right" title="本地启发式估算">
                  out est
                </Th>
                <Th className="text-right" title="provider / local">
                  Δout
                </Th>
                <Th className="text-right">cache↓</Th>
                <Th>provider</Th>
                <Th className="text-right">llm</Th>
                <Th className="text-right">tool</Th>
                <Th className="text-right">total</Th>
                <Th className="text-right" title="厂商上报价 (provider_cost_usd) — 用来和本地计费对账">
                  厂商
                </Th>
                <Th className="text-right" title="厂商 / 本地 — 偏离 1.0 越多越可疑">
                  Δ
                </Th>
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
                  <Td className="text-right text-muted-foreground">
                    {r.est_input_tokens == null ? '—' : fmtTokens(r.est_input_tokens)}
                  </Td>
                  <Td className="text-right">
                    <Ratio actual={r.input_tokens} estimate={r.est_input_tokens} />
                  </Td>
                  <Td className="text-right">{fmtTokens(r.output_tokens)}</Td>
                  <Td className="text-right text-muted-foreground">
                    {r.est_output_tokens == null ? '—' : fmtTokens(r.est_output_tokens)}
                  </Td>
                  <Td className="text-right">
                    <Ratio actual={r.output_tokens} estimate={r.est_output_tokens} />
                  </Td>
                  <Td className="text-right">{fmtTokens(r.cache_read_tokens)}</Td>
                  <Td className="font-mono text-xs text-muted-foreground">
                    {r.reported_provider ?? '—'}
                  </Td>
                  <Td className="text-right">{fmtUsd(r.cost_usd)}</Td>
                  <Td className="text-right">{fmtUsd(r.tool_cost_usd)}</Td>
                  <Td className="text-right">
                    {fmtUsd(Number(r.cost_usd ?? 0) + Number(r.tool_cost_usd ?? 0))}
                  </Td>
                  <Td className="text-right text-muted-foreground">
                    {fmtUsd(r.provider_cost_usd)}
                  </Td>
                  <Td className="text-right">
                    <CostRatio local={r.cost_usd} provider={r.provider_cost_usd} />
                  </Td>
                  <Td className="text-right">{fmtMs(r.latency_ms)}</Td>
                </tr>
              ))}
              {(recent ?? []).length === 0 && (
                <tr>
                  <td colSpan={18} className="px-4 py-8 text-center text-muted-foreground">
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

type DetailStat = { key: string; value: number };

function DetailTable({
  title,
  rows,
  valueKind = 'usd',
}: {
  title: string;
  rows: DetailStat[];
  valueKind?: 'usd' | 'tokens' | 'count';
}) {
  return (
    <div className="rounded-lg border bg-card">
      <h3 className="border-b px-4 py-2 text-sm font-medium">{title}</h3>
      {rows.length === 0 ? (
        <p className="px-4 py-6 text-sm text-muted-foreground">无数据</p>
      ) : (
        <table className="w-full text-sm">
          <tbody>
            {rows.slice(0, 12).map((r) => (
              <tr key={r.key} className="border-b last:border-0">
                <td className="px-4 py-2 font-mono text-xs">{r.key}</td>
                <td className="px-4 py-2 text-right tabular-nums">
                  {valueKind === 'usd'
                    ? fmtUsd(r.value)
                    : valueKind === 'tokens'
                      ? fmtTokens(r.value)
                      : fmtNumber(r.value)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function topCounts(values: (string | null)[]): DetailStat[] {
  const counts = new Map<string, number>();
  for (const raw of values) {
    const key = raw?.trim();
    if (!key) continue;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([key, value]) => ({ key, value }))
    .sort((a, b) => b.value - a.value || a.key.localeCompare(b.key));
}

function aggregateJsonNumbers(values: unknown[]): DetailStat[] {
  const sums = new Map<string, number>();
  const walk = (value: unknown, path: string) => {
    if (typeof value === 'number' && Number.isFinite(value)) {
      sums.set(path, (sums.get(path) ?? 0) + value);
      return;
    }
    if (typeof value === 'string') {
      const n = Number(value);
      if (Number.isFinite(n)) sums.set(path, (sums.get(path) ?? 0) + n);
      return;
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) return;
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      walk(v, path ? `${path}.${k}` : k);
    }
  };
  for (const v of values) walk(v, '');
  return [...sums.entries()]
    .filter(([key]) => key)
    .map(([key, value]) => ({ key, value }))
    .sort((a, b) => b.value - a.value || a.key.localeCompare(b.key));
}

function Th({
  children,
  className,
  title,
}: {
  children: React.ReactNode;
  className?: string;
  title?: string;
}) {
  return (
    <th className={`px-4 py-2 font-medium ${className ?? ''}`} title={title}>
      {children}
    </th>
  );
}
function Td({ children, className }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-2 ${className ?? ''}`}>{children}</td>;
}

// Provider-vs-local ratio cell. 1.00 = perfect agreement, >1 means
// the provider reported more tokens than our heuristic estimated, <1
// the other way. We color cells outside [0.7, 1.3] amber and outside
// [0.5, 1.6] red — those are the "look at this turn closely" thresholds.
// Estimate of 0 (or null) gives '—' rather than a misleading ∞ ratio.
function Ratio({ actual, estimate }: { actual: number; estimate: number | null }) {
  if (estimate == null || estimate === 0) {
    return <span className="text-muted-foreground">—</span>;
  }
  const r = actual / estimate;
  const color =
    r > 1.6 || r < 0.5
      ? 'text-destructive'
      : r > 1.3 || r < 0.7
        ? 'text-amber-600 dark:text-amber-400'
        : 'text-muted-foreground';
  return <span className={`tabular-nums ${color}`}>{r.toFixed(2)}×</span>;
}

// Provider-reported vs locally-computed cost ratio. Used to validate the
// local calculator against gateways that return cost (OpenRouter). Same
// color thresholds as the token ratio above. Null on either side renders
// '—' — WorldRouter does not return cost so this column is intentionally
// blank for rows routed through it.
function CostRatio({
  local,
  provider,
}: {
  local: number | string | null;
  provider: number | string | null;
}) {
  const l = local == null ? null : Number(local);
  const p = provider == null ? null : Number(provider);
  if (l == null || p == null || !Number.isFinite(l) || !Number.isFinite(p) || l === 0) {
    return <span className="text-muted-foreground">—</span>;
  }
  const r = p / l;
  const color =
    r > 1.6 || r < 0.5
      ? 'text-destructive'
      : r > 1.3 || r < 0.7
        ? 'text-amber-600 dark:text-amber-400'
        : 'text-muted-foreground';
  return <span className={`tabular-nums ${color}`}>{r.toFixed(2)}×</span>;
}

// Common task_type values emitted by the router callers — kept in
// sync manually with apps/edge/src/lib/* so the dropdown reflects
// reality without an extra DB roundtrip just for distinct task_types.
const KNOWN_TASKS = ['message_reply', 'title', 'lookback', 'review', 'scroll', 'bot_note'];

function FilterForm({
  start,
  end,
  userId,
  taskType,
  providerId,
  modelId,
  providers,
  models,
}: {
  start: string;
  end: string;
  userId: string;
  taskType: string;
  providerId: string;
  modelId: string;
  providers: { id: string; slug: string; display_name: string }[];
  models: { id: string; slug: string; display_name: string }[];
}) {
  return (
    <form className="flex flex-wrap items-end gap-3 text-sm">
      <FilterField label="开始">
        <input
          type="date"
          name="start"
          defaultValue={start}
          className="rounded-md border border-input bg-background px-2 py-1"
        />
      </FilterField>
      <FilterField label="结束">
        <input
          type="date"
          name="end"
          defaultValue={end}
          className="rounded-md border border-input bg-background px-2 py-1"
        />
      </FilterField>
      <FilterField label="user_id">
        <input
          type="text"
          name="user_id"
          defaultValue={userId}
          placeholder="(全部)"
          className="w-72 rounded-md border border-input bg-background px-2 py-1 font-mono text-xs"
        />
      </FilterField>
      <FilterField label="task">
        <select
          name="task_type"
          defaultValue={taskType}
          className="rounded-md border border-input bg-background px-2 py-1"
        >
          <option value="">(全部)</option>
          {[...new Set([...KNOWN_TASKS, ...(taskType && !KNOWN_TASKS.includes(taskType) ? [taskType] : [])])].map(
            (t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ),
          )}
        </select>
      </FilterField>
      <FilterField label="provider">
        <select
          name="provider_id"
          defaultValue={providerId}
          className="rounded-md border border-input bg-background px-2 py-1"
        >
          <option value="">(全部)</option>
          {providers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.slug}
            </option>
          ))}
        </select>
      </FilterField>
      <FilterField label="model">
        <select
          name="model_id"
          defaultValue={modelId}
          className="rounded-md border border-input bg-background px-2 py-1"
        >
          <option value="">(全部)</option>
          {models.map((m) => (
            <option key={m.id} value={m.id}>
              {m.slug}
            </option>
          ))}
        </select>
      </FilterField>
      <button
        type="submit"
        className="rounded-md border border-input bg-background px-3 py-1.5 hover:bg-accent"
      >
        查询
      </button>
      <a
        href="/audit"
        className="text-xs text-muted-foreground underline"
      >
        清除
      </a>
    </form>
  );
}

function FilterField({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-xs text-muted-foreground">{label}</span>
      {children}
    </label>
  );
}
