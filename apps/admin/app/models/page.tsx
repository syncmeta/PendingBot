import Link from 'next/link';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtNumber, fmtTokens } from '@/lib/format';
import { deleteModel } from './actions';

export default async function ModelsPage() {
  await requireAdmin();
  const supa = supabaseAdmin();

  const { data: models } = await supa
    .from('llm_models')
    .select(
      'id, slug, family, display_name, context_window, max_output_tokens, enabled, deprecated_at, capabilities',
    )
    .order('slug', { ascending: true });

  const { data: aliasRows } = await supa
    .from('llm_model_aliases')
    .select('model_id');
  const aliasCountByModel = new Map<string, number>();
  for (const r of aliasRows ?? []) {
    aliasCountByModel.set(r.model_id, (aliasCountByModel.get(r.model_id) ?? 0) + 1);
  }

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Models</h1>
          <p className="text-sm text-muted-foreground">
            Canonical 模型注册表。bots.model_id 用 slug 引用。
            <Link href="/" className="underline ml-1">
              ← 返回
            </Link>
          </p>
        </div>
        <Link
          href="/models/new"
          className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground"
        >
          新增 model
        </Link>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">slug</th>
              <th className="px-4 py-2 font-medium">name</th>
              <th className="px-4 py-2 font-medium">family</th>
              <th className="px-4 py-2 font-medium text-right">ctx</th>
              <th className="px-4 py-2 font-medium text-right">max out</th>
              <th className="px-4 py-2 font-medium">caps</th>
              <th className="px-4 py-2 font-medium text-right">aliases</th>
              <th className="px-4 py-2 font-medium">状态</th>
              <th className="px-4 py-2" />
            </tr>
          </thead>
          <tbody>
            {(models ?? []).map((m) => {
              const caps = (m.capabilities ?? {}) as Record<string, unknown>;
              const capChips = Object.entries(caps)
                .filter(([, v]) => v === true)
                .map(([k]) => k);
              const isDeprecated = !!m.deprecated_at;
              return (
                <tr key={m.id} className="border-b last:border-0">
                  <td className="px-4 py-2 font-mono text-xs">{m.slug}</td>
                  <td className="px-4 py-2">{m.display_name}</td>
                  <td className="px-4 py-2 text-muted-foreground">{m.family ?? '—'}</td>
                  <td className="px-4 py-2 text-right tabular-nums">
                    {fmtTokens(m.context_window)}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums">
                    {fmtTokens(m.max_output_tokens)}
                  </td>
                  <td className="px-4 py-2">
                    {capChips.length === 0 ? (
                      <span className="text-muted-foreground">—</span>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {capChips.map((c) => (
                          <span
                            key={c}
                            className="rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground"
                          >
                            {c}
                          </span>
                        ))}
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums">
                    {fmtNumber(aliasCountByModel.get(m.id) ?? 0)}
                  </td>
                  <td className="px-4 py-2">
                    {!m.enabled ? (
                      <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                        disabled
                      </span>
                    ) : isDeprecated ? (
                      <span className="rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-800">
                        deprecated
                      </span>
                    ) : (
                      <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                        active
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    <div className="flex items-center justify-end gap-2">
                      <Link
                        href={`/models/${m.id}`}
                        className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                      >
                        编辑
                      </Link>
                      <form action={deleteModel.bind(null, m.id)}>
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
            {(models ?? []).length === 0 && (
              <tr>
                <td colSpan={9} className="px-4 py-8 text-center text-muted-foreground">
                  还没注册 canonical model。新建一个，再去 /aliases 把它映射到具体的
                  provider model id。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        删除会级联删除该 model 下所有 alias。bot 还在引用的 model 不要删——会让 bot
        消息走到 OpenRouter passthrough fallback。
      </p>
    </main>
  );
}
