import { notFound } from 'next/navigation';
import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtPnd, fmtPncMicros, fmtUsd } from '@/lib/format';
import {
  adjustWalletV2,
  cancelPendingDeletion,
  forceDeleteAccount,
  grantCredits,
  updateQuota,
} from '../actions';
import { QuotaForm } from './_form';
import { GrantForm } from './_grant-form';
import { WalletV2Form } from './_wallet-v2-form';
import { ConfirmDeletionAction } from './_deletion-actions';

const COOLDOWN_DAYS = 28;

const DEFAULT_DAILY = 1.0;
const DEFAULT_MONTHLY = 10.0;

export default async function UserDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supa = supabaseAdmin();

  const [
    { data: user },
    { data: quota },
    { data: ledger },
    { data: v2Packs },
    { data: v2Ledger },
  ] = await Promise.all([
    supa
      .from('users')
      .select('id, display_name, email, is_admin, created_at, updated_at, bio, balance_credits, lifetime_topup_credits, lifetime_spent_credits, pending_deletion_at, pending_deletion_sentiment')
      .eq('id', id)
      .maybeSingle(),
    supa.from('user_quota').select('*').eq('user_id', id).maybeSingle(),
    supa
      .from('billing_ledger')
      .select('id, entry_type, delta_credits, reason, created_at')
      .eq('user_id', id)
      .order('created_at', { ascending: false })
      .limit(15),
    // Billing v2 — active packs + recent ledger. Read directly (service
    // role bypasses RLS) so admin sees the v2 wallet alongside v1.
    supa
      .from('packs')
      .select('id, initial_pnc_micros, remaining_pnc_micros, expires_at, status, sales_channel, created_at')
      .eq('owner_user_id', id)
      .eq('status', 'active')
      .order('expires_at', { ascending: true, nullsFirst: false })
      .order('created_at', { ascending: true })
      .limit(50),
    supa
      .from('ledger_entries')
      .select('id, entry_type, delta_pnc_micros, balance_after_pnc_micros, created_at, metadata')
      .eq('owner_user_id', id)
      .order('created_at', { ascending: false })
      .limit(15),
  ]);
  if (!user) notFound();

  const v2TotalMicros = (v2Packs ?? []).reduce(
    (s, p) => s + Number(p.remaining_pnc_micros ?? 0),
    0,
  );

  const pendingDeletionAt = user.pending_deletion_at
    ? new Date(user.pending_deletion_at)
    : null;
  const cooldownEnd = pendingDeletionAt
    ? new Date(pendingDeletionAt.getTime() + COOLDOWN_DAYS * 24 * 3600 * 1000)
    : null;
  const daysLeft = cooldownEnd
    ? Math.max(
        0,
        Math.ceil((cooldownEnd.getTime() - Date.now()) / (24 * 3600 * 1000)),
      )
    : 0;

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
        <h2 className="text-sm font-medium">注销状态</h2>
        <div className="rounded-lg border bg-card p-4 space-y-3 text-sm">
          {pendingDeletionAt ? (
            <>
              <p>
                用户已申请注销,处于 28 天冷静期。
                <span className="ml-1 rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-800">
                  剩余 {daysLeft} 天
                </span>
              </p>
              <p className="text-xs text-muted-foreground">
                申请于 {pendingDeletionAt.toISOString().replace('T', ' ').slice(0, 19)} UTC ·
                到期于 {cooldownEnd!.toISOString().replace('T', ' ').slice(0, 19)} UTC ·
                心情：
                <span className="ml-1 font-mono">
                  {user.pending_deletion_sentiment ?? '—'}
                </span>
              </p>
              <div className="flex items-center gap-2 pt-1">
                <ConfirmDeletionAction
                  action={forceDeleteAccount}
                  userId={user.id}
                  label="立即彻底删除"
                  pendingLabel="正在删除…"
                  confirmText={`确定立即彻底删除 ${user.email ?? user.display_name} 的账号和所有数据？此操作不可撤销。`}
                  successHref="/users"
                />
                <ConfirmDeletionAction
                  action={cancelPendingDeletion}
                  userId={user.id}
                  variant="normal"
                  label="替用户取消注销"
                  pendingLabel="处理中…"
                  confirmText={`确定取消该用户的注销申请？`}
                />
              </div>
            </>
          ) : (
            <>
              <p className="text-muted-foreground">
                用户未申请注销。下面这个按钮跳过冷静期立即删除全部数据,合规 / 滥用场景用。
              </p>
              <ConfirmDeletionAction
                action={forceDeleteAccount}
                userId={user.id}
                label="立即彻底删除（无冷静期）"
                pendingLabel="正在删除…"
                confirmText={`确定立即彻底删除 ${user.email ?? user.display_name} 的账号和所有数据？此操作不可撤销。`}
                successHref="/users"
              />
            </>
          )}
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">余额（PND ∂）</h2>
        <div className="rounded-lg border bg-card p-4 space-y-2">
          <div className="grid grid-cols-3 gap-3 text-sm">
            <div>
              <div className="text-xs uppercase text-muted-foreground">当前余额</div>
              <div className="mt-0.5 text-2xl font-semibold tabular-nums">
                {fmtPnd(user.balance_credits)}
              </div>
            </div>
            <div>
              <div className="text-xs uppercase text-muted-foreground">累计充值</div>
              <div className="mt-0.5 text-lg tabular-nums text-muted-foreground">
                {fmtPnd(user.lifetime_topup_credits)}
              </div>
            </div>
            <div>
              <div className="text-xs uppercase text-muted-foreground">累计消费</div>
              <div className="mt-0.5 text-lg tabular-nums text-muted-foreground">
                {fmtPnd(user.lifetime_spent_credits)}
              </div>
            </div>
          </div>
          <div className="border-t pt-3">
            <p className="mb-2 text-xs text-muted-foreground">
              发放（正数）/ 扣回（负数）PND — 走 billing_admin_grant RPC,
              写 billing_ledger + admin_audit。
            </p>
            <GrantForm action={grantCredits.bind(null, id)} />
          </div>
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">
          余额 v2（PNC · packs）
          <span className="ml-2 rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-normal text-emerald-700">
            billing v2
          </span>
        </h2>
        <div className="rounded-lg border bg-card p-4 space-y-3">
          <div>
            <div className="text-xs uppercase text-muted-foreground">v2 总余额（活跃 packs 求和）</div>
            <div className="mt-0.5 text-2xl font-semibold tabular-nums">
              {fmtPncMicros(v2TotalMicros)}
            </div>
          </div>
          {(v2Packs ?? []).length > 0 && (
            <div className="overflow-x-auto rounded-md border">
              <table className="w-full text-xs">
                <thead className="border-b text-left uppercase text-muted-foreground">
                  <tr>
                    <th className="px-3 py-1.5 font-medium">来源</th>
                    <th className="px-3 py-1.5 font-medium text-right">剩余 / 初始</th>
                    <th className="px-3 py-1.5 font-medium">过期</th>
                  </tr>
                </thead>
                <tbody>
                  {(v2Packs ?? []).map((p) => (
                    <tr key={p.id} className="border-b last:border-0">
                      <td className="px-3 py-1.5">{p.sales_channel}</td>
                      <td className="px-3 py-1.5 text-right tabular-nums">
                        {fmtPncMicros(p.remaining_pnc_micros)} / {fmtPncMicros(p.initial_pnc_micros)}
                      </td>
                      <td className="px-3 py-1.5 text-muted-foreground">
                        {p.expires_at
                          ? new Date(p.expires_at).toISOString().slice(0, 10)
                          : '永不'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <div className="border-t pt-3">
            <p className="mb-2 text-xs text-muted-foreground">
              发放（正数 → admin_grant pack，永不过期）/ 扣回（负数 → FIFO 扣
              active packs）。走 billing_v2_admin_adjust RPC，写 ledger_entries
              adjustment + admin_audit。&gt; 100 PNC 需二次确认。
            </p>
            <WalletV2Form action={adjustWalletV2.bind(null, id)} />
          </div>
          {(v2Ledger ?? []).length > 0 && (
            <div className="overflow-x-auto rounded-md border">
              <table className="w-full text-xs">
                <thead className="border-b text-left uppercase text-muted-foreground">
                  <tr>
                    <th className="px-3 py-1.5 font-medium">时间</th>
                    <th className="px-3 py-1.5 font-medium">类型</th>
                    <th className="px-3 py-1.5 font-medium text-right">变化</th>
                    <th className="px-3 py-1.5 font-medium text-right">余额后</th>
                  </tr>
                </thead>
                <tbody>
                  {(v2Ledger ?? []).map((l) => (
                    <tr key={l.id} className="border-b last:border-0">
                      <td className="px-3 py-1.5 font-mono">
                        {new Date(l.created_at).toISOString().replace('T', ' ').slice(0, 19)}
                      </td>
                      <td className="px-3 py-1.5">{l.entry_type}</td>
                      <td
                        className={`px-3 py-1.5 text-right tabular-nums ${
                          Number(l.delta_pnc_micros) > 0 ? 'text-emerald-700' : 'text-amber-700'
                        }`}
                      >
                        {Number(l.delta_pnc_micros) > 0 ? '+' : ''}
                        {fmtPncMicros(l.delta_pnc_micros)}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-muted-foreground">
                        {fmtPncMicros(l.balance_after_pnc_micros)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>

      {(ledger ?? []).length > 0 && (
        <section className="space-y-3">
          <h2 className="text-sm font-medium">最近账本（前 15 条）</h2>
          <div className="overflow-x-auto rounded-lg border bg-card">
            <table className="w-full text-sm">
              <thead className="border-b text-left text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="px-4 py-2 font-medium">时间</th>
                  <th className="px-4 py-2 font-medium">类型</th>
                  <th className="px-4 py-2 font-medium text-right">变化</th>
                  <th className="px-4 py-2 font-medium">理由</th>
                </tr>
              </thead>
              <tbody>
                {(ledger ?? []).map((r) => (
                  <tr key={r.id} className="border-b last:border-0">
                    <td className="px-4 py-2 font-mono text-xs">
                      {new Date(r.created_at).toISOString().replace('T', ' ').slice(0, 19)}
                    </td>
                    <td className="px-4 py-2">{r.entry_type}</td>
                    <td
                      className={`px-4 py-2 text-right tabular-nums ${
                        Number(r.delta_credits) > 0 ? 'text-emerald-700' : 'text-amber-700'
                      }`}
                    >
                      {Number(r.delta_credits) > 0 ? '+' : ''}
                      {fmtPnd(r.delta_credits)}
                    </td>
                    <td className="px-4 py-2 text-xs text-muted-foreground">
                      {r.reason ?? '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <section className="space-y-3">
        <h2 className="text-sm font-medium">配额（旧的 USD 维度,观察用）</h2>
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
          action={updateQuota.bind(null, id)}
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
