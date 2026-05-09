import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtNumber, fmtUsd } from '@/lib/format';
import { forceDeleteAccount, generateLoginCode, resetQuotaUsed } from './actions';
import { ConfirmDeletionAction } from './[id]/_deletion-actions';
import { GenerateLoginCodeButton } from './_login-code-button';

type SearchParams = { sort?: string; q?: string };

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const sort = params.sort ?? 'monthly_used';
  const q = (params.q ?? '').trim();

  const supa = supabaseAdmin();

  // Pull users + their quota row (one-to-one). Two queries because
  // PostgREST embeds need a FK constraint to be discoverable; user_quota's
  // FK is to auth.users not pendingbot.users so the join doesn't auto-wire.
  let query = supa
    .from('users')
    .select(
      'id, display_name, email, is_admin, created_at, updated_at, pending_deletion_at',
    );
  if (q) {
    // ilike across email and display_name for the search box. Cheap
    // pre-launch; add a tsv index later if it groans.
    query = query.or(`email.ilike.%${q}%,display_name.ilike.%${q}%`);
  }
  const { data: users } = await query.order('created_at', { ascending: false }).limit(500);

  const userIds = (users ?? []).map((u) => u.id);
  const { data: quotas } = userIds.length
    ? await supa.from('user_quota').select('*').in('user_id', userIds)
    : { data: [] as {
        user_id: string;
        daily_limit_usd: number;
        monthly_limit_usd: number;
        daily_used_usd: number;
        monthly_used_usd: number;
      }[] };
  const quotaMap = new Map((quotas ?? []).map((q) => [q.user_id, q]));

  // Sort in JS — small set, no index gymnastics.
  const rows = (users ?? []).slice();
  if (sort === 'monthly_used') {
    rows.sort((a, b) => {
      const av = Number(quotaMap.get(a.id)?.monthly_used_usd ?? 0);
      const bv = Number(quotaMap.get(b.id)?.monthly_used_usd ?? 0);
      return bv - av;
    });
  } else if (sort === 'daily_used') {
    rows.sort((a, b) => {
      const av = Number(quotaMap.get(a.id)?.daily_used_usd ?? 0);
      const bv = Number(quotaMap.get(b.id)?.daily_used_usd ?? 0);
      return bv - av;
    });
  }
  // 'recent' default falls through (already ordered by created_at desc)

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Users & Quota</h1>
          <p className="text-sm text-muted-foreground">
            {fmtNumber((users ?? []).length)} 个用户。按花费 / 注册时间排，限额可点行末"编辑"修改。
          </p>
        </div>
        <form className="flex items-center gap-2 text-sm">
          <input
            type="search"
            name="q"
            placeholder="email / 名字..."
            defaultValue={q}
            className="rounded-md border border-input bg-background px-2 py-1"
          />
          <select
            name="sort"
            defaultValue={sort}
            className="rounded-md border border-input bg-background px-2 py-1"
          >
            <option value="monthly_used">月花费 ↓</option>
            <option value="daily_used">日花费 ↓</option>
            <option value="recent">最近注册 ↓</option>
          </select>
          <button
            type="submit"
            className="rounded-md border border-input px-3 py-1 hover:bg-accent"
          >
            筛选
          </button>
        </form>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">用户</th>
              <th className="px-4 py-2 font-medium">注册</th>
              <th className="px-4 py-2 font-medium text-right">日 used / limit</th>
              <th className="px-4 py-2 font-medium text-right">月 used / limit</th>
              <th className="px-4 py-2 font-medium">admin</th>
              <th className="px-4 py-2" />
            </tr>
          </thead>
          <tbody>
            {rows.map((u) => {
              const quota = quotaMap.get(u.id);
              const dailyUsed = Number(quota?.daily_used_usd ?? 0);
              const dailyLimit = Number(quota?.daily_limit_usd ?? 0);
              const monthlyUsed = Number(quota?.monthly_used_usd ?? 0);
              const monthlyLimit = Number(quota?.monthly_limit_usd ?? 0);
              const dailyHot = dailyLimit > 0 && dailyUsed / dailyLimit >= 0.8;
              const monthlyHot = monthlyLimit > 0 && monthlyUsed / monthlyLimit >= 0.8;
              return (
                <tr key={u.id} className="border-b last:border-0">
                  <td className="px-4 py-2">
                    <div className="flex items-center gap-2">
                      <span>{u.display_name || '(无名)'}</span>
                      {u.pending_deletion_at && (
                        <span
                          className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium uppercase text-amber-800"
                          title={`已申请注销 — ${new Date(u.pending_deletion_at).toISOString().slice(0, 10)} 起冷静期`}
                        >
                          注销中
                        </span>
                      )}
                    </div>
                    <div className="text-xs text-muted-foreground">{u.email ?? '—'}</div>
                  </td>
                  <td className="px-4 py-2 text-xs text-muted-foreground">
                    {new Date(u.created_at).toISOString().slice(0, 10)}
                  </td>
                  <td
                    className={`px-4 py-2 text-right tabular-nums ${
                      dailyHot ? 'text-amber-700 font-medium' : ''
                    }`}
                  >
                    {quota ? `${fmtUsd(dailyUsed)} / ${fmtUsd(dailyLimit)}` : '—'}
                  </td>
                  <td
                    className={`px-4 py-2 text-right tabular-nums ${
                      monthlyHot ? 'text-amber-700 font-medium' : ''
                    }`}
                  >
                    {quota ? `${fmtUsd(monthlyUsed)} / ${fmtUsd(monthlyLimit)}` : '—'}
                  </td>
                  <td className="px-4 py-2">
                    {u.is_admin ? (
                      <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                        admin
                      </span>
                    ) : (
                      <span className="text-xs text-muted-foreground">—</span>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    <div className="flex items-center justify-end gap-2 flex-wrap">
                      <Link
                        href={`/users/${u.id}`}
                        className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                      >
                        编辑限额
                      </Link>
                      <form action={resetQuotaUsed.bind(null, u.id)}>
                        <button
                          type="submit"
                          className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                          title="把 daily/monthly 用量计数器手动归零"
                        >
                          重置用量
                        </button>
                      </form>
                      <GenerateLoginCodeButton
                        action={generateLoginCode}
                        userId={u.id}
                      />
                      {u.pending_deletion_at && (
                        <ConfirmDeletionAction
                          action={forceDeleteAccount}
                          userId={u.id}
                          size="sm"
                          label="立即注销"
                          pendingLabel="注销中..."
                          confirmText={`确定立即彻底删除 ${u.email ?? u.display_name ?? u.id} 的账号和所有数据？此操作不可撤销,会跳过 28 天冷静期。`}
                        />
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                  没有匹配的用户
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        橙色高亮表示已用 ≥ 80% 限额。日/月 used 由后台异步累加（router 还没接 quota 检查；现在
        这两个字段是观察用，不会真的拒绝请求——后续接成本扣费时再让它具备拦截能力）。
      </p>
    </main>
  );
}
