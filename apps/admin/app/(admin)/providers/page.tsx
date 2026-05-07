import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtNumber } from '@/lib/format';
import { toggleProviderEnabled, deleteProvider } from './actions';

export default async function ProvidersPage() {
  const supa = supabaseAdmin();

  const { data: providers } = await supa
    .from('llm_providers')
    .select('id, slug, display_name, base_url, auth_type, secret_ref, enabled, priority, notes')
    .order('priority', { ascending: true });

  // Per-provider alias count for quick at-a-glance signal of "is this
  // provider actually wired up to anything".
  const { data: aliasCounts } = await supa
    .from('llm_model_aliases')
    .select('provider_id');
  const aliasCountByProvider = new Map<string, number>();
  for (const r of aliasCounts ?? []) {
    aliasCountByProvider.set(
      r.provider_id,
      (aliasCountByProvider.get(r.provider_id) ?? 0) + 1,
    );
  }

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Providers</h1>
          <p className="text-sm text-muted-foreground">LLM 网关 / 直连厂商。</p>
        </div>
        <Link
          href="/providers/new"
          className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground"
        >
          新增 provider
        </Link>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">slug</th>
              <th className="px-4 py-2 font-medium">name</th>
              <th className="px-4 py-2 font-medium">base_url</th>
              <th className="px-4 py-2 font-medium">secret_ref</th>
              <th className="px-4 py-2 font-medium text-right">priority</th>
              <th className="px-4 py-2 font-medium text-right">aliases</th>
              <th className="px-4 py-2 font-medium">状态</th>
              <th className="px-4 py-2 font-medium" />
            </tr>
          </thead>
          <tbody>
            {(providers ?? []).map((p) => (
              <tr key={p.id} className="border-b last:border-0">
                <td className="px-4 py-2 font-mono text-xs">{p.slug}</td>
                <td className="px-4 py-2">{p.display_name}</td>
                <td className="px-4 py-2 font-mono text-xs text-muted-foreground">
                  {p.base_url}
                </td>
                <td className="px-4 py-2 font-mono text-xs">{p.secret_ref}</td>
                <td className="px-4 py-2 text-right tabular-nums">{p.priority}</td>
                <td className="px-4 py-2 text-right tabular-nums">
                  {fmtNumber(aliasCountByProvider.get(p.id) ?? 0)}
                </td>
                <td className="px-4 py-2">
                  {p.enabled ? (
                    <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                      enabled
                    </span>
                  ) : (
                    <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                      disabled
                    </span>
                  )}
                </td>
                <td className="px-4 py-2">
                  <div className="flex items-center justify-end gap-2">
                    <Link
                      href={`/providers/${p.id}`}
                      className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                    >
                      编辑
                    </Link>
                    <form action={toggleProviderEnabled.bind(null, p.id)}>
                      <button
                        type="submit"
                        className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                      >
                        {p.enabled ? '停用' : '启用'}
                      </button>
                    </form>
                    {p.slug !== 'openrouter' && (
                      <form action={deleteProvider.bind(null, p.id)}>
                        <button
                          type="submit"
                          className="rounded border border-destructive/50 px-2 py-1 text-xs text-destructive hover:bg-destructive/10"
                        >
                          删除
                        </button>
                      </form>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {(providers ?? []).length === 0 && (
              <tr>
                <td colSpan={8} className="px-4 py-8 text-center text-muted-foreground">
                  还没有 provider。点右上方"新增"开始。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        删除会级联删除该 provider 下的所有 model alias。OpenRouter 是 fallback 锚点，不允许删（可停用）。secret_ref 是 Wrangler 上的 env var 名，密钥本体不入库——添加新 provider 前先 `wrangler secret put 该名字` 把 key 推上去，否则 worker 跑到该 provider 时会抛错。
      </p>
    </main>
  );
}
