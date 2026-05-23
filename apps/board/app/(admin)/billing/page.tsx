import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtPnd, fmtNumber, fmtUsd } from '@/lib/format';
import { MarkupEditor } from './markup-editor';
import { setMarkup } from './actions';

// Display ratio — must match USD_TO_PND in apps/edge/src/lib/billing.ts.
// Used here only to render USD-equivalent next to PND for the "ops
// headlines" cards (rate hint, not strict reporting).
const USD_TO_PND = 2700;

// Fallback when billing_config.markup is missing — matches
// DEFAULT_MARKUP in apps/edge/src/lib/billing.ts. The DB value is the
// source of truth at runtime.
const DEFAULT_MARKUP = 2.5;

function billingCategory(taskType: string, metadata?: unknown): { key: string; label: string } {
  const source =
    metadata && typeof metadata === 'object'
      ? (metadata as Record<string, unknown>).source
      : null;
  if (taskType === 'message_reply') return { key: 'chat.reply', label: '聊天回复' };
  if (taskType === 'group_router') return { key: 'group.routing', label: '群聊路由' };
  if (taskType === 'voice_call') return { key: 'voice.call', label: '语音通话' };
  if (taskType === 'envelope' || taskType === 'scroll') return { key: 'envelope.write', label: '来信生成' };
  if (taskType === 'title') return { key: 'system.title', label: '自动标题' };
  if (taskType === 'lookback') return { key: 'memory.lookback', label: '记忆回看' };
  if (taskType === 'chat_memo') return { key: 'memory.memo', label: '聊天备忘' };
  if (taskType === 'bot_note') return { key: 'memory.bot_note', label: '机器人笔记' };
  if (taskType === 'tool' || source === 'web_tool') return { key: 'tool.web', label: '工具调用' };
  return { key: `other.${taskType || 'unknown'}`, label: taskType || '未知' };
}

export default async function BillingDashboardPage() {
  const supa = supabaseAdmin();
  const since7d = new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString();
  const since24h = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

  // ── Snapshot: balance/lifetime sums + low-balance count ────────────
  const [usersAgg, threshold, markupRow] = await Promise.all([
    supa.from('users').select(
      'balance_credits, lifetime_topup_credits, lifetime_spent_credits',
    ),
    supa
      .from('billing_config')
      .select('value')
      .eq('key', 'min_balance_threshold')
      .maybeSingle(),
    supa
      .from('billing_config')
      .select('value')
      .eq('key', 'markup')
      .maybeSingle(),
  ]);
  const markup = ((): number => {
    const raw = markupRow.data?.value;
    const n = typeof raw === 'number' ? raw : Number(raw);
    return Number.isFinite(n) && n > 0 ? n : DEFAULT_MARKUP;
  })();
  const users = usersAgg.data ?? [];
  const totalBalance = users.reduce((s, u) => s + Number(u.balance_credits ?? 0), 0);
  const lifetimeTopup = users.reduce(
    (s, u) => s + Number(u.lifetime_topup_credits ?? 0),
    0,
  );
  const lifetimeSpent = users.reduce(
    (s, u) => s + Number(u.lifetime_spent_credits ?? 0),
    0,
  );
  const minThreshold = Number(threshold.data?.value ?? 0);
  const lowBalanceCount = users.filter(
    (u) => minThreshold > 0 && Number(u.balance_credits ?? 0) < minThreshold,
  ).length;

  // ── 24h / 7d activity from audit_log + ledger ──────────────────────
  const [
    consume24h,
    consume7d,
    ledger24h,
    ledger7d,
    redeemed7d,
  ] = await Promise.all([
    supa
      .from('audit_log')
      .select('cost_credits, cost_usd')
      .gte('created_at', since24h)
      .in('billing_status', ['billed', 'unbilled']),
    supa
      .from('audit_log')
      .select('cost_credits')
      .gte('created_at', since7d)
      .in('billing_status', ['billed', 'unbilled']),
    supa
      .from('billing_ledger')
      .select('entry_type, delta_credits')
      .gte('created_at', since24h),
    supa
      .from('billing_ledger')
      .select('entry_type, delta_credits')
      .gte('created_at', since7d),
    supa
      .from('redemption_codes')
      .select('credits, redeemed_at')
      .gte('redeemed_at', since7d)
      .eq('status', 'used'),
  ]);

  const consumeCredits24h = (consume24h.data ?? []).reduce(
    (s, r) => s + Number(r.cost_credits ?? 0),
    0,
  );
  const consumeUsd24h = (consume24h.data ?? []).reduce(
    (s, r) => s + Number(r.cost_usd ?? 0),
    0,
  );
  const consumeCredits7d = (consume7d.data ?? []).reduce(
    (s, r) => s + Number(r.cost_credits ?? 0),
    0,
  );
  const sumByKind = (rows: { entry_type: string; delta_credits: number }[]) =>
    rows.reduce<Record<string, { count: number; credits: number }>>((acc, r) => {
      const k = r.entry_type;
      const cur = acc[k] ?? { count: 0, credits: 0 };
      cur.count += 1;
      cur.credits += Number(r.delta_credits ?? 0);
      acc[k] = cur;
      return acc;
    }, {});
  const ledger24hKinds = sumByKind(ledger24h.data ?? []);
  const ledger7dKinds = sumByKind(ledger7d.data ?? []);

  const grantsCredits24h = ledger24hKinds.grant?.credits ?? 0;
  const redeemCount7d = (redeemed7d.data ?? []).length;
  const redeemCredits7d = (redeemed7d.data ?? []).reduce(
    (s, r) => s + Number(r.credits ?? 0),
    0,
  );

  // ── Top spenders last 7d ───────────────────────────────────────────
  // No view yet; fold in JS with a server-side per-row select. At launch
  // scale this is fine (500 users × ~10 calls/day = 5k rows).
  const { data: spendRows } = await supa
    .from('audit_log')
    .select('user_id, task_type, metadata, cost_credits')
    .gte('created_at', since7d)
    .in('billing_status', ['billed', 'unbilled']);
  const spendByUser = new Map<string, number>();
  const spendByCategory = new Map<string, { label: string; count: number; credits: number }>();
  for (const row of spendRows ?? []) {
    const category = billingCategory(row.task_type ?? '', row.metadata);
    const cat = spendByCategory.get(category.key) ?? {
      label: category.label,
      count: 0,
      credits: 0,
    };
    cat.count += 1;
    cat.credits += Number(row.cost_credits ?? 0);
    spendByCategory.set(category.key, cat);
    if (!row.user_id) continue;
    spendByUser.set(
      row.user_id,
      (spendByUser.get(row.user_id) ?? 0) + Number(row.cost_credits ?? 0),
    );
  }
  const topSpenderIds = [...spendByUser.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10);
  const allCategories = [...spendByCategory.entries()]
    .map(([key, v]) => ({ key, ...v }))
    .sort((a, b) => b.credits - a.credits);
  const { data: topUserRows } = topSpenderIds.length
    ? await supa
        .from('users')
        .select('id, display_name, email, balance_credits')
        .in(
          'id',
          topSpenderIds.map(([id]) => id),
        )
    : { data: [] as { id: string; display_name: string; email: string | null; balance_credits: number }[] };
  const topUserMap = new Map((topUserRows ?? []).map((u) => [u.id, u]));

  // ── Low-balance users list (pre-block stage) ───────────────────────
  const lowBalanceUsers = minThreshold > 0
    ? (await supa
        .from('users')
        .select('id, display_name, email, balance_credits')
        .lt('balance_credits', minThreshold)
        .order('balance_credits', { ascending: true })
        .limit(15)).data ?? []
    : [];

  // Display helpers
  const displayUsd = (pnd: number) =>
    fmtUsd(pnd / USD_TO_PND / markup);

  return (
    <main className="container py-10 space-y-8">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Billing</h1>
          <p className="text-sm text-muted-foreground">
            PND（∂）计费 · markup {markup}× · $1 = {USD_TO_PND} ∂
          </p>
        </div>
        <div className="flex gap-2 text-sm">
          <Link
            href="/billing/codes"
            className="rounded-md border border-input px-3 py-1.5 hover:bg-accent"
          >
            兑换码
          </Link>
          <Link
            href="/users"
            className="rounded-md border border-input px-3 py-1.5 hover:bg-accent"
          >
            用户/发放
          </Link>
        </div>
      </header>

      <MarkupEditor current={markup} action={setMarkup} />

      {/* Snapshot cards */}
      <section className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Card label="用户" value={fmtNumber(users.length)} />
        <Card
          label="流通余额"
          value={fmtPnd(totalBalance)}
          hint={`≈ ${displayUsd(totalBalance)}`}
        />
        <Card
          label="累计充值"
          value={fmtPnd(lifetimeTopup)}
          hint={`≈ ${displayUsd(lifetimeTopup)}`}
        />
        <Card
          label="累计消费"
          value={fmtPnd(lifetimeSpent)}
          hint={`成本 ≈ ${fmtUsd(lifetimeSpent / USD_TO_PND / markup)}`}
        />
      </section>

      {/* 24h / 7d activity */}
      <section className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Card
          label="24h 消费"
          value={fmtPnd(consumeCredits24h)}
          hint={`成本 ≈ ${fmtUsd(consumeUsd24h)} · ${(consume24h.data ?? []).length} 次调用`}
        />
        <Card
          label="24h 发放"
          value={fmtPnd(grantsCredits24h)}
          hint={`${ledger24hKinds.grant?.count ?? 0} 笔 admin grant`}
        />
        <Card
          label="7d 兑换码"
          value={fmtPnd(redeemCredits7d)}
          hint={`${redeemCount7d} 次兑换`}
        />
        <Card
          label="7d 消费"
          value={fmtPnd(consumeCredits7d)}
          hint={`成本 ≈ ${displayUsd(consumeCredits7d)}`}
        />
      </section>

      {/* Low-balance + Top spenders side by side */}
      <section className="grid gap-6 md:grid-cols-2">
        <div className="space-y-3">
          <h2 className="text-sm font-medium">
            低于阈值（{fmtPnd(minThreshold)}）
            <span className="ml-2 text-xs text-muted-foreground">
              {lowBalanceCount} 人 · 这些用户下次发消息会被 402 拦
            </span>
          </h2>
          <div className="overflow-x-auto rounded-lg border bg-card">
            <table className="w-full text-sm">
              <thead className="border-b text-left text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="px-4 py-2 font-medium">用户</th>
                  <th className="px-4 py-2 font-medium text-right">余额</th>
                  <th className="px-4 py-2" />
                </tr>
              </thead>
              <tbody>
                {lowBalanceUsers.map((u) => (
                  <tr key={u.id} className="border-b last:border-0">
                    <td className="px-4 py-2">
                      <div>{u.display_name || '(无名)'}</div>
                      <div className="text-xs text-muted-foreground">{u.email ?? '—'}</div>
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums text-amber-700">
                      {fmtPnd(u.balance_credits)}
                    </td>
                    <td className="px-4 py-2 text-right">
                      <Link
                        href={`/users/${u.id}`}
                        className="rounded border border-input px-2 py-0.5 text-xs hover:bg-accent"
                      >
                        发放
                      </Link>
                    </td>
                  </tr>
                ))}
                {lowBalanceUsers.length === 0 && (
                  <tr>
                    <td colSpan={3} className="px-4 py-6 text-center text-muted-foreground">
                      没人低于阈值
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>

        <div className="space-y-3">
          <h2 className="text-sm font-medium">
            7d 消费榜
            <span className="ml-2 text-xs text-muted-foreground">前 10 名</span>
          </h2>
          <div className="overflow-x-auto rounded-lg border bg-card">
            <table className="w-full text-sm">
              <thead className="border-b text-left text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="px-4 py-2 font-medium">用户</th>
                  <th className="px-4 py-2 font-medium text-right">7d 消费</th>
                  <th className="px-4 py-2 font-medium text-right">当前余额</th>
                </tr>
              </thead>
              <tbody>
                {topSpenderIds.map(([id, credits]) => {
                  const u = topUserMap.get(id);
                  return (
                    <tr key={id} className="border-b last:border-0">
                      <td className="px-4 py-2">
                        <Link
                          href={`/users/${id}`}
                          className="hover:underline"
                        >
                          {u?.display_name || '(无名)'}
                        </Link>
                        <div className="text-xs text-muted-foreground">
                          {u?.email ?? '—'}
                        </div>
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">
                        {fmtPnd(credits)}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                        {fmtPnd(u?.balance_credits ?? 0)}
                      </td>
                    </tr>
                  );
                })}
                {topSpenderIds.length === 0 && (
                  <tr>
                    <td colSpan={3} className="px-4 py-6 text-center text-muted-foreground">
                      最近 7 天没有计费消费
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">
          7d 消费分类
          <span className="ml-2 text-xs text-muted-foreground">所有分类</span>
        </h2>
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">分类</th>
                <th className="px-4 py-2 font-medium">key</th>
                <th className="px-4 py-2 font-medium text-right">次数</th>
                <th className="px-4 py-2 font-medium text-right">PND</th>
              </tr>
            </thead>
            <tbody>
              {allCategories.map((c) => (
                <tr key={c.key} className="border-b last:border-0">
                  <td className="px-4 py-2">{c.label}</td>
                  <td className="px-4 py-2 font-mono text-xs text-muted-foreground">{c.key}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{fmtNumber(c.count)}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{fmtPnd(c.credits)}</td>
                </tr>
              ))}
              {allCategories.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-4 py-6 text-center text-muted-foreground">
                    最近 7 天没有计费消费
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <p className="text-xs text-muted-foreground">
        7d 兑换 + grant 笔数：兑换 {ledger7dKinds.redemption?.count ?? 0} ·
        grant {ledger7dKinds.grant?.count ?? 0} ·
        signup_bonus {ledger7dKinds.signup_bonus?.count ?? 0} ·
        refund {ledger7dKinds.refund?.count ?? 0} ·
        adjust {ledger7dKinds.adjust?.count ?? 0}
      </p>
    </main>
  );
}

function Card({
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint?: string;
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
      <div className="mt-1 text-2xl font-semibold tabular-nums">{value}</div>
      {hint && <div className="mt-1 text-xs text-muted-foreground">{hint}</div>}
    </div>
  );
}
