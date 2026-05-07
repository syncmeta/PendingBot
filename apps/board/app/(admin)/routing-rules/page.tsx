import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { toggleRuleEnabled, deleteRule } from './actions';

export default async function RoutingRulesPage() {
  const supa = supabaseAdmin();

  const { data: rows } = await supa
    .from('task_routing_rules')
    .select(
      `id, task_type, match_priority, enabled, notes,
       override_model:llm_models!task_routing_rules_override_model_fkey ( slug, display_name ),
       prefer_provider:llm_providers!task_routing_rules_prefer_provider_fkey ( slug, display_name )`,
    )
    .order('task_type', { ascending: true })
    .order('match_priority', { ascending: true });

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Task routing rules</h1>
          <p className="text-sm text-muted-foreground">
            按 task_type 覆盖路由——把 'title'/'ai_picks' 这种廉价 task 锁定 cheap
            model，或者整体偏好某个 provider。
          </p>
        </div>
        <Link
          href="/routing-rules/new"
          className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground"
        >
          新增规则
        </Link>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">task_type</th>
              <th className="px-4 py-2 font-medium text-right">priority</th>
              <th className="px-4 py-2 font-medium">override model</th>
              <th className="px-4 py-2 font-medium">prefer provider</th>
              <th className="px-4 py-2 font-medium">备注</th>
              <th className="px-4 py-2 font-medium">状态</th>
              <th className="px-4 py-2" />
            </tr>
          </thead>
          <tbody>
            {(rows ?? []).map((r) => {
              const m = r.override_model as { slug?: string; display_name?: string } | null;
              const p = r.prefer_provider as { slug?: string; display_name?: string } | null;
              return (
                <tr key={r.id} className="border-b last:border-0">
                  <td className="px-4 py-2 font-mono text-xs">{r.task_type}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{r.match_priority}</td>
                  <td className="px-4 py-2 font-mono text-xs">
                    {m?.slug ? (
                      <span>
                        {m.slug}
                        <span className="ml-1 text-muted-foreground">({m.display_name})</span>
                      </span>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                  </td>
                  <td className="px-4 py-2 font-mono text-xs">
                    {p?.slug ? (
                      <span>
                        {p.slug}
                        <span className="ml-1 text-muted-foreground">({p.display_name})</span>
                      </span>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-xs text-muted-foreground">
                    {r.notes ?? '—'}
                  </td>
                  <td className="px-4 py-2">
                    {r.enabled ? (
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
                        href={`/routing-rules/${r.id}`}
                        className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                      >
                        编辑
                      </Link>
                      <form action={toggleRuleEnabled.bind(null, r.id)}>
                        <button
                          type="submit"
                          className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                        >
                          {r.enabled ? '停用' : '启用'}
                        </button>
                      </form>
                      <form action={deleteRule.bind(null, r.id)}>
                        <button
                          type="submit"
                          className="rounded border border-destructive/50 px-2 py-1 text-xs text-destructive hover:bg-destructive/10"
                        >
                          删除
                        </button>
                      </form>
                    </div>
                  </td>
                </tr>
              );
            })}
            {(rows ?? []).length === 0 && (
              <tr>
                <td colSpan={7} className="px-4 py-8 text-center text-muted-foreground">
                  没有规则。空表 = 路由器走默认 alias 选择。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        同一 task_type 多条 enabled 规则按 priority 升序竞争——只有 priority 最低的一条生效。
      </p>
    </main>
  );
}
