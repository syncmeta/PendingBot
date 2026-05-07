import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtCredits } from '@/lib/format';
import { disableCode, enableCode, issueCodes } from './actions';
import { JustIssued } from './_just-issued';

type SearchParams = {
  just?: string;
  just_codes?: string;
  err?: string;
  status?: 'enabled' | 'disabled' | 'used' | 'all';
};

export default async function CodesPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const supa = supabaseAdmin();

  // Recent batches — group by batch_label, count codes by status.
  const { data: allCodes } = await supa
    .from('redemption_codes')
    .select('id, code, credits, status, batch_label, created_at, redeemed_at, redeemed_by')
    .order('created_at', { ascending: false })
    .limit(500);
  const codes = allCodes ?? [];

  // Build batch summary
  type Batch = {
    label: string;
    enabled: number;
    used: number;
    disabled: number;
    creditsEach: number; // assume uniform per batch (issue is uniform)
    earliest: string;
  };
  const batchMap = new Map<string, Batch>();
  for (const c of codes) {
    const k = c.batch_label ?? '(unlabeled)';
    const cur =
      batchMap.get(k) ?? {
        label: k,
        enabled: 0,
        used: 0,
        disabled: 0,
        creditsEach: Number(c.credits),
        earliest: c.created_at,
      };
    if (c.status === 'enabled') cur.enabled += 1;
    else if (c.status === 'used') cur.used += 1;
    else if (c.status === 'disabled') cur.disabled += 1;
    if (c.created_at < cur.earliest) cur.earliest = c.created_at;
    batchMap.set(k, cur);
  }
  const batches = [...batchMap.values()]
    .sort((a, b) => (a.earliest < b.earliest ? 1 : -1))
    .slice(0, 30);

  // Filter codes table by status filter
  const statusFilter = params.status ?? 'enabled';
  const filtered =
    statusFilter === 'all' ? codes : codes.filter((c) => c.status === statusFilter);
  const tableCodes = filtered.slice(0, 100);

  // Just-issued (passed via redirect from issueCodes)
  let justCodes: string[] = [];
  if (params.just_codes) {
    justCodes = params.just_codes.split(',').filter(Boolean);
  } else if (params.just) {
    // Resolve by batch label — pull all enabled+used in that batch
    const { data } = await supa
      .from('redemption_codes')
      .select('code')
      .eq('batch_label', params.just)
      .order('created_at', { ascending: false })
      .limit(1000);
    justCodes = (data ?? []).map((c) => c.code);
  }

  return (
    <main className="container py-10 space-y-8">
      <header>
        <h1 className="text-2xl font-bold tracking-tight">兑换码</h1>
        <p className="text-sm text-muted-foreground">
          按批次发码,用户在 iOS / Web 端 POST /v1/me/redeem 兑换。每个码只能用一次。
        </p>
      </header>

      {params.err && (
        <div className="rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
          发码失败：{decodeURIComponent(params.err)}
        </div>
      )}

      {justCodes.length > 0 && <JustIssued codes={justCodes} label={params.just ?? null} />}

      {/* Issue form */}
      <section className="space-y-3">
        <h2 className="text-sm font-medium">发新码</h2>
        <form action={issueCodes} className="rounded-lg border bg-card p-4 space-y-3 max-w-xl">
          <div className="grid grid-cols-3 gap-3">
            <label className="text-sm space-y-1">
              <span className="text-muted-foreground">数量 (1–1000)</span>
              <input
                type="number"
                name="count"
                defaultValue="10"
                min="1"
                max="1000"
                required
                className="w-full rounded-md border border-input bg-background px-2 py-1 text-sm"
              />
            </label>
            <label className="text-sm space-y-1">
              <span className="text-muted-foreground">每码 credits</span>
              <input
                type="number"
                name="credits"
                defaultValue="1000"
                min="1"
                required
                className="w-full rounded-md border border-input bg-background px-2 py-1 text-sm"
              />
            </label>
            <label className="text-sm space-y-1">
              <span className="text-muted-foreground">批次标签 (可选)</span>
              <input
                type="text"
                name="label"
                placeholder="beta-2026-05"
                className="w-full rounded-md border border-input bg-background px-2 py-1 text-sm"
              />
            </label>
          </div>
          <div className="flex items-center justify-between text-xs text-muted-foreground">
            <span>批次标签方便你之后按批查询、停用整批。不填可用,但要在生成后立刻保存返回的码。</span>
            <button
              type="submit"
              className="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground hover:opacity-90"
            >
              发码
            </button>
          </div>
        </form>
      </section>

      {/* Batches summary */}
      <section className="space-y-3">
        <h2 className="text-sm font-medium">批次（最近 30 个）</h2>
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">批次</th>
                <th className="px-4 py-2 font-medium">每码</th>
                <th className="px-4 py-2 font-medium text-right">enabled</th>
                <th className="px-4 py-2 font-medium text-right">used</th>
                <th className="px-4 py-2 font-medium text-right">disabled</th>
                <th className="px-4 py-2 font-medium">起始</th>
              </tr>
            </thead>
            <tbody>
              {batches.map((b) => (
                <tr key={b.label} className="border-b last:border-0">
                  <td className="px-4 py-2 font-mono text-xs">{b.label}</td>
                  <td className="px-4 py-2 tabular-nums">{fmtCredits(b.creditsEach)}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{b.enabled}</td>
                  <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                    {b.used}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                    {b.disabled}
                  </td>
                  <td className="px-4 py-2 text-xs text-muted-foreground">
                    {new Date(b.earliest).toISOString().slice(0, 10)}
                  </td>
                </tr>
              ))}
              {batches.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-6 text-center text-muted-foreground">
                    还没发过码。用上面的表单发第一批吧。
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {/* Codes table with filter */}
      <section className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-medium">单个码</h2>
          <form className="text-xs">
            <select
              name="status"
              defaultValue={statusFilter}
              onChange={(e) => e.currentTarget.form?.requestSubmit()}
              className="rounded-md border border-input bg-background px-2 py-1"
            >
              <option value="enabled">未使用</option>
              <option value="used">已使用</option>
              <option value="disabled">已停用</option>
              <option value="all">全部</option>
            </select>
          </form>
        </div>
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">code</th>
                <th className="px-4 py-2 font-medium text-right">credits</th>
                <th className="px-4 py-2 font-medium">批次</th>
                <th className="px-4 py-2 font-medium">状态</th>
                <th className="px-4 py-2 font-medium">兑换时间</th>
                <th className="px-4 py-2" />
              </tr>
            </thead>
            <tbody>
              {tableCodes.map((c) => (
                <tr key={c.id} className="border-b last:border-0">
                  <td className="px-4 py-2 font-mono text-xs">{c.code}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{fmtCredits(c.credits)}</td>
                  <td className="px-4 py-2 text-xs text-muted-foreground">
                    {c.batch_label ?? '—'}
                  </td>
                  <td className="px-4 py-2">
                    {c.status === 'used' ? (
                      <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                        used
                      </span>
                    ) : c.status === 'disabled' ? (
                      <span className="rounded bg-zinc-200 px-2 py-0.5 text-xs text-zinc-600">
                        disabled
                      </span>
                    ) : (
                      <span className="rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-700">
                        enabled
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-xs text-muted-foreground">
                    {c.redeemed_at
                      ? new Date(c.redeemed_at).toISOString().slice(0, 16).replace('T', ' ')
                      : '—'}
                  </td>
                  <td className="px-4 py-2 text-right">
                    {c.status === 'enabled' && (
                      <form action={disableCode.bind(null, c.id)}>
                        <button
                          type="submit"
                          className="rounded border border-input px-2 py-0.5 text-xs hover:bg-accent"
                        >
                          停用
                        </button>
                      </form>
                    )}
                    {c.status === 'disabled' && (
                      <form action={enableCode.bind(null, c.id)}>
                        <button
                          type="submit"
                          className="rounded border border-input px-2 py-0.5 text-xs hover:bg-accent"
                        >
                          启用
                        </button>
                      </form>
                    )}
                  </td>
                </tr>
              ))}
              {tableCodes.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-6 text-center text-muted-foreground">
                    没有匹配的码
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {filtered.length > 100 && (
          <p className="text-xs text-muted-foreground">
            只显示前 100 条;按批次/状态筛选缩小范围,或在 Studio 直接查 redemption_codes 表。
          </p>
        )}
      </section>

      <p className="text-xs text-muted-foreground">
        所有发码 / 启停操作都写到 admin_audit,可在
        <Link href="/admin-audit" className="ml-1 underline">
          Admin audit
        </Link>
        查看。
      </p>
    </main>
  );
}
