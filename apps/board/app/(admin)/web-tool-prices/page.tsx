import { supabaseAdmin } from '@/lib/supabase/admin';
import { updateWebToolPrice } from './actions';
import { PriceRowForm, type PriceRow, type UsageCell } from './_row';

// Wholesale prices for external web search / crawl providers, edited
// inline. The edge worker (apps/edge/src/lib/web-meter.ts) caches the
// table with a 60s TTL — saved changes take effect on the next worker
// isolate that refreshes its cache, no deploy needed.

// Fallback markup if billing_config.markup row is missing — matches
// DEFAULT_MARKUP in apps/edge/src/lib/billing.ts.
const DEFAULT_MARKUP = 2.5;

export default async function WebToolPricesPage() {
  const supa = supabaseAdmin();
  const since7d = new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString();
  const [pricesRes, usageRes, markupRow] = await Promise.all([
    supa
      .from('web_tool_prices')
      .select('provider, kind, unit_cost_usd, notes, updated_at')
      .order('kind', { ascending: true })
      .order('provider', { ascending: true }),
    // 7-day usage by provider+kind so the admin sees which price actually
    // moves the needle. Single audit_web_tool_calls scan; the row count
    // is small enough that grouping in JS is cheaper than a custom view.
    supa
      .from('audit_web_tool_calls')
      .select('provider, kind, cost_usd, status')
      .gte('created_at', since7d),
    supa
      .from('billing_config')
      .select('value')
      .eq('key', 'markup')
      .maybeSingle(),
  ]);
  const rows = pricesRes.data;
  const usage = usageRes.data;
  const markup = ((): number => {
    const raw = markupRow.data?.value;
    const n = typeof raw === 'number' ? raw : Number(raw);
    return Number.isFinite(n) && n > 0 ? n : DEFAULT_MARKUP;
  })();

  const usageByKey = new Map<
    string,
    { count: number; errors: number; usd: number }
  >();
  for (const u of usage ?? []) {
    const k = `${u.provider}:${u.kind}`;
    const cur = usageByKey.get(k) ?? { count: 0, errors: 0, usd: 0 };
    cur.count += 1;
    if (u.status === 'error') cur.errors += 1;
    cur.usd += Number(u.cost_usd ?? 0);
    usageByKey.set(k, cur);
  }

  const priceRows = (rows ?? []) as PriceRow[];

  return (
    <main className="container py-10 space-y-6">
      <header>
        <h1 className="text-2xl font-bold tracking-tight">Web tool prices</h1>
        <p className="text-sm text-muted-foreground">
          外部搜索 / 抓取服务的批发单价。Edge worker 每 60 秒刷新一次缓存——
          保存后下一个调用周期生效。新增 provider 需要先在 web.ts 接好再走迁移。
        </p>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">provider / kind</th>
              <th className="px-4 py-2 font-medium">unit cost</th>
              <th className="px-4 py-2 font-medium">7d 调用</th>
            </tr>
          </thead>
          <tbody>
            {priceRows.length === 0 && (
              <tr>
                <td
                  colSpan={3}
                  className="px-4 py-8 text-center text-muted-foreground"
                >
                  没有定价行。迁移 20260511034611_web_tool_billing 是否已应用？
                </td>
              </tr>
            )}
            {priceRows.map((row) => {
              const usageCell: UsageCell =
                usageByKey.get(`${row.provider}:${row.kind}`) ?? null;
              return (
                <PriceRowForm
                  key={`${row.provider}:${row.kind}`}
                  row={row}
                  usage={usageCell}
                  markup={markup}
                  action={updateWebToolPrice.bind(null, row.provider, row.kind)}
                />
              );
            })}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        删除 / 新增 provider 走迁移——这里只改单价和备注。billing_debit 用的
        是合并后的 cost_credits（LLM + 工具），单价改了之后影响的是下一次
        recordAudit 的 PND 扣款。
      </p>
    </main>
  );
}
