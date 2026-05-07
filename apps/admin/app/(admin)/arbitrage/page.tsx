import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtDay, fmtMs, fmtNumber, fmtUsd } from '@/lib/format';
import { SavingsChart, type DailySavings } from './savings-chart';

// Reference provider for the counterfactual. OpenRouter is what we'd
// pay if we didn't route through any cheaper alternative — every other
// provider's savings are measured against it.
const REFERENCE_PROVIDER_SLUG = 'openrouter';

function defaultRange(): { start: string; end: string } {
  const now = new Date();
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const start = new Date(end);
  start.setUTCDate(start.getUTCDate() - 29);
  return { start: start.toISOString().slice(0, 10), end: end.toISOString().slice(0, 10) };
}

const PER_M = 1_000_000;

type AliasRow = {
  id: string;
  model_id: string;
  provider_id: string;
  input_price: number | null;
  cached_input_price: number | null;
  output_price: number | null;
  cache_write_price: number | null;
  llm_providers: { slug: string } | null;
};

type AuditRow = {
  created_at: string;
  input_tokens: number | null;
  output_tokens: number | null;
  cache_read_tokens: number | null;
  cache_write_tokens: number | null;
  cost_usd: string | number | null;
  latency_ms: number | null;
  provider_id: string | null;
  model_alias_id: string | null;
  status: string | null;
};

function priceTokens(alias: AliasRow, row: AuditRow): number | null {
  let known = false;
  let cost = 0;
  const input = row.input_tokens ?? 0;
  const output = row.output_tokens ?? 0;
  const cacheR = row.cache_read_tokens ?? 0;
  const cacheW = row.cache_write_tokens ?? 0;

  if (alias.input_price != null && input) {
    cost += (input * alias.input_price) / PER_M;
    known = true;
  }
  if (alias.output_price != null && output) {
    cost += (output * alias.output_price) / PER_M;
    known = true;
  }
  if (alias.cached_input_price != null && cacheR) {
    cost += (cacheR * alias.cached_input_price) / PER_M;
    known = true;
  } else if (alias.input_price != null && cacheR) {
    // Provider has no cached_input_price recorded — degrade to input
    // price so we at least don't pretend cache_read is free.
    cost += (cacheR * alias.input_price) / PER_M;
    known = true;
  }
  if (alias.cache_write_price != null && cacheW) {
    cost += (cacheW * alias.cache_write_price) / PER_M;
    known = true;
  } else if (alias.input_price != null && cacheW) {
    cost += (cacheW * alias.input_price) / PER_M;
    known = true;
  }
  return known ? cost : null;
}

export default async function ArbitragePage({
  searchParams,
}: {
  searchParams: Promise<{ start?: string; end?: string }>;
}) {
  const params = await searchParams;
  const fb = defaultRange();
  const start = params.start ?? fb.start;
  const end = params.end ?? fb.end;
  const startBound = `${start}T00:00:00Z`;
  const endDate = new Date(`${end}T00:00:00Z`);
  endDate.setUTCDate(endDate.getUTCDate() + 1);
  const endBound = endDate.toISOString();

  const supa = supabaseAdmin();

  // Pull all aliases (with provider slug + price). Tiny table, used as
  // an in-memory price book for both actual and counterfactual.
  const { data: aliasesRaw } = await supa
    .from('llm_model_aliases')
    .select(
      `id, model_id, provider_id, input_price, cached_input_price, output_price, cache_write_price,
       llm_providers ( slug )`,
    );
  const aliases = (aliasesRaw ?? []) as AliasRow[];
  const aliasById = new Map(aliases.map((a) => [a.id, a]));
  const referenceAliasByModel = new Map<string, AliasRow>();
  for (const a of aliases) {
    if (a.llm_providers?.slug === REFERENCE_PROVIDER_SLUG) {
      referenceAliasByModel.set(a.model_id, a);
    }
  }

  // Provider id → slug, for the request-distribution table.
  const { data: providers } = await supa
    .from('llm_providers')
    .select('id, slug, display_name');
  const providerById = new Map((providers ?? []).map((p) => [p.id, p]));

  // Audit slice over the chosen window. We pull rows that have a
  // model_alias_id — without it there's no canonical model to compare
  // across, so they can't contribute to arbitrage math (but they still
  // show up in /audit).
  const { data: auditRaw, error } = await supa
    .from('audit_log')
    .select(
      'created_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, latency_ms, provider_id, model_alias_id, status',
    )
    .gte('created_at', startBound)
    .lt('created_at', endBound)
    .not('model_alias_id', 'is', null);
  const audit = (auditRaw ?? []) as AuditRow[];

  // Per-provider request totals across the whole window — counts every
  // audited row with a provider_id, even ones we can't price-compare.
  const { data: providerCountsRaw } = await supa
    .from('audit_log')
    .select('provider_id, latency_ms, status')
    .gte('created_at', startBound)
    .lt('created_at', endBound)
    .not('provider_id', 'is', null);
  type ProviderCountRow = NonNullable<typeof providerCountsRaw>[number];
  const providerCounts = (providerCountsRaw ?? []) as ProviderCountRow[];

  // ── Aggregations ──────────────────────────────────────────────
  let actualTotal = 0;
  let counterfactualTotal = 0;
  let comparableRequests = 0;
  let unattributedRequests = audit.length; // rows we can't compare yet
  const dailyMap = new Map<string, DailySavings>();
  const byModel = new Map<
    string,
    { modelId: string; actual: number; counter: number; requests: number }
  >();

  for (const row of audit) {
    const alias = row.model_alias_id ? aliasById.get(row.model_alias_id) : undefined;
    if (!alias) continue;
    const refAlias = referenceAliasByModel.get(alias.model_id);
    if (!refAlias) continue; // no OpenRouter mirror to compare against

    const actual = priceTokens(alias, row);
    const counter = priceTokens(refAlias, row);
    if (actual == null || counter == null) continue;

    actualTotal += actual;
    counterfactualTotal += counter;
    comparableRequests++;
    unattributedRequests--;

    const day = fmtDay(row.created_at);
    const cur = dailyMap.get(day) ?? { day, actual: 0, counterfactual: 0 };
    cur.actual += actual;
    cur.counterfactual += counter;
    dailyMap.set(day, cur);

    const m = byModel.get(alias.model_id) ?? {
      modelId: alias.model_id,
      actual: 0,
      counter: 0,
      requests: 0,
    };
    m.actual += actual;
    m.counter += counter;
    m.requests += 1;
    byModel.set(alias.model_id, m);
  }

  const totalSavings = counterfactualTotal - actualTotal;
  const savingsPct =
    counterfactualTotal > 0 ? totalSavings / counterfactualTotal : null;
  const timeline = [...dailyMap.values()].sort((a, b) => a.day.localeCompare(b.day));

  // Provider request distribution + p50/p95-ish via simple sort.
  const providerStats = new Map<
    string,
    { requests: number; errors: number; latencies: number[] }
  >();
  for (const r of providerCounts) {
    if (!r.provider_id) continue;
    const cur = providerStats.get(r.provider_id) ?? {
      requests: 0,
      errors: 0,
      latencies: [],
    };
    cur.requests++;
    if (r.status === 'error') cur.errors++;
    if (r.latency_ms != null) cur.latencies.push(r.latency_ms);
    providerStats.set(r.provider_id, cur);
  }

  // Resolve model id → slug for the by-model table.
  const modelIds = [...byModel.keys()];
  const { data: modelRows } = modelIds.length
    ? await supa.from('llm_models').select('id, slug, display_name').in('id', modelIds)
    : { data: [] as { id: string; slug: string; display_name: string }[] };
  const modelMap = new Map((modelRows ?? []).map((m) => [m.id, m]));

  // ── Render ─────────────────────────────────────────────────────
  return (
    <main className="container py-10 space-y-10">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Arbitrage</h1>
          <p className="text-sm text-muted-foreground">
            实际花的钱 vs 若全走 OpenRouter 应该花的钱。
          </p>
        </div>
        <DateRangeForm start={start} end={end} />
      </header>

      {error && (
        <p className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          查询出错：{error.message}
        </p>
      )}

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat
          label="若全走 OpenRouter"
          value={fmtUsd(counterfactualTotal)}
          sub="counterfactual"
        />
        <Stat label="实际花费" value={fmtUsd(actualTotal)} sub="actual" />
        <Stat
          label="省了"
          value={fmtUsd(totalSavings)}
          sub={savingsPct == null ? '—' : `${(savingsPct * 100).toFixed(1)}%`}
          accent={totalSavings > 0}
        />
        <Stat
          label="可对比请求"
          value={fmtNumber(comparableRequests)}
          sub={
            unattributedRequests > 0
              ? `${fmtNumber(unattributedRequests)} 条还未配对（缺 OpenRouter alias 或缺 alias 价格）`
              : '全部已配对'
          }
        />
      </section>

      <section className="rounded-lg border bg-card p-5">
        <h2 className="text-sm font-medium">每日花费对比</h2>
        <p className="text-xs text-muted-foreground">
          深色 = 实际，浅灰 = 若全走 OpenRouter。两条柱越拉开省得越多。
        </p>
        <div className="mt-4">
          {timeline.length === 0 ? (
            <p className="py-12 text-center text-sm text-muted-foreground">
              这段时间没有可对比的请求。请确认 audit_log 已经在写 model_alias_id（先做了 router migration），
              并且每个 canonical model 在 OpenRouter 都有 alias 行做对照基线。
            </p>
          ) : (
            <SavingsChart data={timeline} />
          )}
        </div>
      </section>

      <section>
        <h2 className="text-sm font-medium">按模型拆分</h2>
        <div className="mt-3 overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">model</th>
                <th className="px-4 py-2 font-medium text-right">请求数</th>
                <th className="px-4 py-2 font-medium text-right">实际</th>
                <th className="px-4 py-2 font-medium text-right">若全走 OR</th>
                <th className="px-4 py-2 font-medium text-right">省了</th>
                <th className="px-4 py-2 font-medium text-right">折扣率</th>
              </tr>
            </thead>
            <tbody>
              {[...byModel.values()]
                .sort((a, b) => b.counter - b.actual - (a.counter - a.actual))
                .map((m) => {
                  const saved = m.counter - m.actual;
                  const ratio = m.counter > 0 ? saved / m.counter : null;
                  const model = modelMap.get(m.modelId);
                  return (
                    <tr key={m.modelId} className="border-b last:border-0">
                      <td className="px-4 py-2 font-mono text-xs">
                        {model?.slug ?? m.modelId.slice(0, 8)}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">
                        {fmtNumber(m.requests)}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">{fmtUsd(m.actual)}</td>
                      <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                        {fmtUsd(m.counter)}
                      </td>
                      <td
                        className={`px-4 py-2 text-right tabular-nums ${
                          saved > 0 ? 'text-emerald-700 font-medium' : ''
                        }`}
                      >
                        {fmtUsd(saved)}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">
                        {ratio == null ? '—' : `${(ratio * 100).toFixed(1)}%`}
                      </td>
                    </tr>
                  );
                })}
              {byModel.size === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                    没有可对比数据
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 className="text-sm font-medium">Provider 表现</h2>
        <p className="text-xs text-muted-foreground">
          请求分布 + 错误率 + 延迟分位。"WorldRouter 真的更快/更慢吗"在这看。
        </p>
        <div className="mt-3 overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">provider</th>
                <th className="px-4 py-2 font-medium text-right">请求数</th>
                <th className="px-4 py-2 font-medium text-right">占比</th>
                <th className="px-4 py-2 font-medium text-right">错误率</th>
                <th className="px-4 py-2 font-medium text-right">中位延迟</th>
                <th className="px-4 py-2 font-medium text-right">p95 延迟</th>
              </tr>
            </thead>
            <tbody>
              {[...providerStats.entries()]
                .map(([id, s]) => ({ id, ...s }))
                .sort((a, b) => b.requests - a.requests)
                .map((s) => {
                  const totalReqs = providerCounts.length || 1;
                  const share = s.requests / totalReqs;
                  const errRate = s.requests > 0 ? s.errors / s.requests : 0;
                  const sorted = [...s.latencies].sort((a, b) => a - b);
                  const p50 = sorted.length ? sorted[Math.floor(sorted.length * 0.5)] : null;
                  const p95 = sorted.length ? sorted[Math.floor(sorted.length * 0.95)] : null;
                  const provider = providerById.get(s.id);
                  return (
                    <tr key={s.id} className="border-b last:border-0">
                      <td className="px-4 py-2">{provider?.display_name ?? provider?.slug ?? s.id.slice(0, 8)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{fmtNumber(s.requests)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{(share * 100).toFixed(1)}%</td>
                      <td
                        className={`px-4 py-2 text-right tabular-nums ${
                          errRate > 0.05 ? 'text-destructive' : ''
                        }`}
                      >
                        {(errRate * 100).toFixed(1)}%
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">{fmtMs(p50)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{fmtMs(p95)}</td>
                    </tr>
                  );
                })}
              {providerStats.size === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                    暂无 provider 归因数据
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
  sub,
  accent,
}: {
  label: string;
  value: string;
  sub?: string;
  accent?: boolean;
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div
        className={
          accent
            ? 'mt-1 text-2xl font-bold tabular-nums text-emerald-700'
            : 'mt-1 text-2xl font-semibold tabular-nums'
        }
      >
        {value}
      </div>
      {sub && <div className="mt-1 text-xs text-muted-foreground">{sub}</div>}
    </div>
  );
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
