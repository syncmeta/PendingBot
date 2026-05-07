import Link from 'next/link';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

// Read view for pendingbot.admin_audit. Every provider/model/alias
// CRUD action lands a row here; this page is "who changed what when".
// Default 100 rows; bump via ?limit=N. No filters yet — keep small
// until volume motivates them.

type SearchParams = { limit?: string };

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 1000;

const ACTION_PALETTE: Record<string, string> = {
  create: 'bg-emerald-100 text-emerald-700',
  update: 'bg-blue-100 text-blue-700',
  enable: 'bg-emerald-100 text-emerald-700',
  disable: 'bg-amber-100 text-amber-800',
  delete: 'bg-rose-100 text-rose-700',
};

function actionBadge(action: string): string {
  const verb = action.split('.').pop() ?? action;
  return ACTION_PALETTE[verb] ?? 'bg-muted text-muted-foreground';
}

export default async function AdminAuditPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  await requireAdmin();
  const params = await searchParams;
  const limit = Math.min(MAX_LIMIT, Math.max(1, Number.parseInt(params.limit ?? '', 10) || DEFAULT_LIMIT));

  const supa = supabaseAdmin();
  const { data: rows } = await supa
    .from('admin_audit')
    .select('id, created_at, actor_id, action, target_kind, target_id, before, after, ip')
    .order('created_at', { ascending: false })
    .limit(limit);

  // Resolve actor display names.
  const actorIds = [...new Set((rows ?? []).map((r) => r.actor_id).filter((x): x is string => !!x))];
  const { data: actors } = actorIds.length
    ? await supa.from('users').select('id, display_name, email').in('id', actorIds)
    : { data: [] as { id: string; display_name: string; email: string | null }[] };
  const actorMap = new Map((actors ?? []).map((a) => [a.id, a]));

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Admin Audit</h1>
          <p className="text-sm text-muted-foreground">
            管理后台所有写操作的留痕（创建 / 更新 / 启停 / 删除）。
            <Link href="/" className="underline ml-1">
              ← 返回
            </Link>
          </p>
        </div>
        <p className="text-xs text-muted-foreground">显示最近 {limit} 条</p>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">时间</th>
              <th className="px-4 py-2 font-medium">操作人</th>
              <th className="px-4 py-2 font-medium">action</th>
              <th className="px-4 py-2 font-medium">目标</th>
              <th className="px-4 py-2 font-medium">变更</th>
              <th className="px-4 py-2 font-medium">ip</th>
            </tr>
          </thead>
          <tbody>
            {(rows ?? []).map((r) => {
              const actor = r.actor_id ? actorMap.get(r.actor_id) : null;
              return (
                <tr key={r.id} className="border-b align-top last:border-0">
                  <td className="whitespace-nowrap px-4 py-2 font-mono text-xs">
                    {new Date(r.created_at).toISOString().replace('T', ' ').slice(0, 19)}
                  </td>
                  <td className="px-4 py-2">
                    {actor ? (
                      <>
                        <div>{actor.display_name || '(无名)'}</div>
                        <div className="text-xs text-muted-foreground">{actor.email}</div>
                      </>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    <span
                      className={`inline-block rounded px-2 py-0.5 text-xs ${actionBadge(r.action)}`}
                    >
                      {r.action}
                    </span>
                  </td>
                  <td className="px-4 py-2">
                    <div className="text-xs text-muted-foreground">{r.target_kind}</div>
                    <div className="font-mono text-xs">{r.target_id}</div>
                  </td>
                  <td className="px-4 py-2">
                    <Diff before={r.before} after={r.after} />
                  </td>
                  <td className="px-4 py-2 font-mono text-xs text-muted-foreground">
                    {r.ip ?? '—'}
                  </td>
                </tr>
              );
            })}
            {(rows ?? []).length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                  还没有 admin 操作记录
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </main>
  );
}

// Compute the changed-fields summary between before/after jsonb. For
// create rows before is null → list every after key as "+key=val". For
// delete it's the inverse. Updates show only fields that actually
// differ; unchanged keys are omitted to keep the diff readable.
function Diff({ before, after }: { before: unknown; after: unknown }) {
  const b = (before ?? null) as Record<string, unknown> | null;
  const a = (after ?? null) as Record<string, unknown> | null;

  if (!b && !a) return <span className="text-muted-foreground">—</span>;

  if (!b && a) {
    // Pure create — show a few salient keys, skip jsonb noise.
    return <KvList kv={a} prefix="+" tone="text-emerald-700" />;
  }
  if (b && !a) {
    return <KvList kv={b} prefix="−" tone="text-rose-700" />;
  }

  const keys = new Set([...Object.keys(b ?? {}), ...Object.keys(a ?? {})]);
  const changed: { key: string; from: unknown; to: unknown }[] = [];
  for (const k of keys) {
    const before = b?.[k];
    const after = a?.[k];
    if (JSON.stringify(before) !== JSON.stringify(after)) {
      changed.push({ key: k, from: before, to: after });
    }
  }
  if (changed.length === 0) {
    return <span className="text-muted-foreground">无字段差异</span>;
  }

  return (
    <ul className="space-y-0.5 text-xs">
      {changed.map((c) => (
        <li key={c.key} className="font-mono">
          <span className="text-muted-foreground">{c.key}</span>:{' '}
          <span className="text-rose-700">{stringify(c.from)}</span>
          {' → '}
          <span className="text-emerald-700">{stringify(c.to)}</span>
        </li>
      ))}
    </ul>
  );
}

const SKIP_KEYS = new Set(['id', 'created_at', 'updated_at']);

function KvList({
  kv,
  prefix,
  tone,
}: {
  kv: Record<string, unknown>;
  prefix: string;
  tone: string;
}) {
  const entries = Object.entries(kv).filter(([k]) => !SKIP_KEYS.has(k));
  if (entries.length === 0) return <span className="text-muted-foreground">—</span>;
  return (
    <ul className="space-y-0.5 text-xs">
      {entries.slice(0, 8).map(([k, v]) => (
        <li key={k} className={`font-mono ${tone}`}>
          {prefix} <span className="opacity-70">{k}</span>: {stringify(v)}
        </li>
      ))}
      {entries.length > 8 && (
        <li className="text-muted-foreground">…其余 {entries.length - 8} 字段省略</li>
      )}
    </ul>
  );
}

function stringify(v: unknown): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  try {
    const s = JSON.stringify(v);
    return s.length > 60 ? s.slice(0, 60) + '…' : s;
  } catch {
    return String(v);
  }
}
