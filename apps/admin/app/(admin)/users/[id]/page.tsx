import { notFound } from 'next/navigation';
import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtUsd } from '@/lib/format';
import { updateQuota, type QuotaFormState } from '../actions';
import { QuotaForm } from './_form';

const DEFAULT_DAILY = 1.0;
const DEFAULT_MONTHLY = 10.0;

export default async function UserDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supa = supabaseAdmin();

  const [{ data: user }, { data: quota }] = await Promise.all([
    supa
      .from('users')
      .select('id, display_name, email, is_admin, created_at, updated_at, bio')
      .eq('id', id)
      .maybeSingle(),
    supa.from('user_quota').select('*').eq('user_id', id).maybeSingle(),
  ]);
  if (!user) notFound();

  // Pull last 30 days of audit_log for this user — quick "what's this
  // user actually been doing" preview without sending them to /audit.
  const since = new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString();
  const { data: recent } = await supa
    .from('audit_log')
    .select('task_type, model_id, cost_usd, created_at, status')
    .eq('user_id', id)
    .gte('created_at', since)
    .order('created_at', { ascending: false })
    .limit(20);

  const action = async (prev: QuotaFormState, formData: FormData) =>
    updateQuota(id, prev, formData);

  return (
    <main className="container max-w-3xl py-10 space-y-8">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">{user.display_name || '(无名)'}</h1>
        <p className="text-sm text-muted-foreground">{user.email ?? '—'}</p>
        {user.bio && <p className="mt-2 text-sm text-muted-foreground">{user.bio}</p>}
        <p className="mt-2 text-xs text-muted-foreground">
          注册于 {new Date(user.created_at).toISOString().slice(0, 10)}
          {user.is_admin && (
            <span className="ml-2 rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
              admin
            </span>
          )}
        </p>
      </div>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">配额</h2>
        {quota && (
          <div className="rounded-lg border bg-card p-4 text-sm">
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">本日已用</span>
              <span className="tabular-nums">
                {fmtUsd(quota.daily_used_usd)} / {fmtUsd(quota.daily_limit_usd)}
              </span>
            </div>
            <div className="mt-1 flex items-center justify-between">
              <span className="text-muted-foreground">本月已用</span>
              <span className="tabular-nums">
                {fmtUsd(quota.monthly_used_usd)} / {fmtUsd(quota.monthly_limit_usd)}
              </span>
            </div>
          </div>
        )}
        <QuotaForm
          action={action}
          initial={{
            daily_limit_usd: Number(quota?.daily_limit_usd ?? DEFAULT_DAILY),
            monthly_limit_usd: Number(quota?.monthly_limit_usd ?? DEFAULT_MONTHLY),
          }}
        />
        {!quota && (
          <p className="text-xs text-muted-foreground">
            该用户还没有 user_quota 行——保存上面的限额会自动 upsert 一行（默认 ${DEFAULT_DAILY} /
            ${DEFAULT_MONTHLY}）。
          </p>
        )}
      </section>

      <section className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-medium">最近 30 天 LLM 调用（前 20 条）</h2>
          <Link
            href={`/audit?user_id=${id}`}
            className="text-xs underline text-muted-foreground"
          >
            完整 audit →
          </Link>
        </div>
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">时间</th>
                <th className="px-4 py-2 font-medium">task</th>
                <th className="px-4 py-2 font-medium">model</th>
                <th className="px-4 py-2 font-medium">状态</th>
                <th className="px-4 py-2 font-medium text-right">cost</th>
              </tr>
            </thead>
            <tbody>
              {(recent ?? []).map((r, i) => (
                <tr key={i} className="border-b last:border-0">
                  <td className="px-4 py-2 font-mono text-xs">
                    {new Date(r.created_at).toISOString().replace('T', ' ').slice(0, 19)}
                  </td>
                  <td className="px-4 py-2">{r.task_type}</td>
                  <td className="px-4 py-2 font-mono text-xs">{r.model_id}</td>
                  <td className="px-4 py-2">
                    {r.status === 'error' ? (
                      <span className="text-destructive">error</span>
                    ) : (
                      r.status ?? 'ok'
                    )}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums">{fmtUsd(r.cost_usd)}</td>
                </tr>
              ))}
              {(recent ?? []).length === 0 && (
                <tr>
                  <td colSpan={5} className="px-4 py-6 text-center text-muted-foreground">
                    最近 30 天没有 LLM 调用记录
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
