import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtUsd } from '@/lib/format';
import { ActionButton } from '@/components/action-button';
import { toggleAliasEnabled, deleteAlias } from './actions';

export default async function AliasesPage() {
  const supa = supabaseAdmin();

  const { data: rows } = await supa
    .from('llm_model_aliases')
    .select(
      `id, provider_model_id, weight, enabled,
       input_price, cached_input_price, output_price,
       llm_models ( id, slug, display_name ),
       llm_providers ( id, slug, display_name )`,
    )
    .order('weight', { ascending: false });

  // Group by canonical model so the panel reads "for each model, here
  // are the providers it can run on" rather than a flat dump.
  type AliasRow = NonNullable<typeof rows>[number];
  const grouped = new Map<string, { model: AliasRow['llm_models']; aliases: AliasRow[] }>();
  for (const r of rows ?? []) {
    if (!r.llm_models) continue;
    const key = r.llm_models.id;
    const cur = grouped.get(key) ?? { model: r.llm_models, aliases: [] };
    cur.aliases.push(r);
    grouped.set(key, cur);
  }

  // Cheapest-input price per model — used to render a "% vs cheapest"
  // hint per row when a model has more than one provider alias.
  const cheapestByModel = new Map<string, number>();
  for (const [k, g] of grouped) {
    const min = g.aliases
      .filter((a) => a.input_price != null)
      .reduce(
        (m, a) => (a.input_price! < m ? a.input_price! : m),
        Number.POSITIVE_INFINITY,
      );
    if (Number.isFinite(min)) cheapestByModel.set(k, min);
  }

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Model Aliases</h1>
          <p className="text-sm text-muted-foreground">
            (model × provider) 映射表 + 价格 + 路由权重。
          </p>
        </div>
        <div className="flex gap-2">
          <Link
            href="/aliases/upstream"
            className="rounded-md border border-input px-3 py-1.5 text-sm hover:bg-accent"
          >
            上游对账
          </Link>
          <Link
            href="/aliases/new"
            className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground"
          >
            新增 alias
          </Link>
        </div>
      </header>

      {grouped.size === 0 ? (
        <div className="rounded-lg border bg-card p-8 text-center text-sm text-muted-foreground">
          还没有 alias。先去 <Link href="/models" className="underline">/models</Link>{' '}
          注册 canonical model 和 <Link href="/providers" className="underline">/providers</Link>{' '}
          配 provider，再回来添 alias 把它们连起来。
        </div>
      ) : (
        <div className="space-y-6">
          {[...grouped.values()]
            .sort((a, b) => a.model!.slug.localeCompare(b.model!.slug))
            .map((g) => (
              <ModelGroup
                key={g.model!.id}
                model={g.model!}
                aliases={g.aliases}
                cheapestInput={cheapestByModel.get(g.model!.id)}
              />
            ))}
        </div>
      )}
    </main>
  );
}

type AliasRow = {
  id: string;
  provider_model_id: string;
  weight: number;
  enabled: boolean;
  input_price: number | null;
  cached_input_price: number | null;
  output_price: number | null;
  llm_providers: { id: string; slug: string; display_name: string } | null;
};

function ModelGroup({
  model,
  aliases,
  cheapestInput,
}: {
  model: { id: string; slug: string; display_name: string };
  aliases: AliasRow[];
  cheapestInput?: number;
}) {
  return (
    <section className="rounded-lg border bg-card">
      <div className="flex items-center justify-between border-b px-5 py-3">
        <div>
          <span className="text-sm font-medium">{model.display_name}</span>
          <span className="ml-2 font-mono text-xs text-muted-foreground">{model.slug}</span>
        </div>
        <Link href={`/aliases/new?model_id=${model.id}`} className="text-xs underline">
          + alias
        </Link>
      </div>
      <table className="w-full text-sm">
        <thead className="border-b text-left text-xs uppercase text-muted-foreground">
          <tr>
            <th className="px-5 py-2 font-medium">provider</th>
            <th className="px-5 py-2 font-medium">provider_model_id</th>
            <th className="px-5 py-2 font-medium text-right">weight</th>
            <th className="px-5 py-2 font-medium text-right">input</th>
            <th className="px-5 py-2 font-medium text-right">cached</th>
            <th className="px-5 py-2 font-medium text-right">output</th>
            <th className="px-5 py-2 font-medium text-right">vs 最低</th>
            <th className="px-5 py-2 font-medium">状态</th>
            <th className="px-5 py-2" />
          </tr>
        </thead>
        <tbody>
          {aliases
            .sort((a, b) => b.weight - a.weight)
            .map((a) => {
              const ratio =
                cheapestInput != null && a.input_price != null && cheapestInput > 0
                  ? a.input_price / cheapestInput
                  : null;
              return (
                <tr key={a.id} className="border-b last:border-0">
                  <td className="px-5 py-2">
                    {a.llm_providers?.display_name ?? a.llm_providers?.slug ?? '—'}
                  </td>
                  <td className="px-5 py-2 font-mono text-xs">{a.provider_model_id}</td>
                  <td className="px-5 py-2 text-right tabular-nums">{a.weight}</td>
                  <td className="px-5 py-2 text-right tabular-nums">
                    {fmtUsd(a.input_price)}
                  </td>
                  <td className="px-5 py-2 text-right tabular-nums text-muted-foreground">
                    {fmtUsd(a.cached_input_price)}
                  </td>
                  <td className="px-5 py-2 text-right tabular-nums">
                    {fmtUsd(a.output_price)}
                  </td>
                  <td className="px-5 py-2 text-right tabular-nums">
                    {ratio == null ? (
                      <span className="text-muted-foreground">—</span>
                    ) : ratio === 1 ? (
                      <span className="text-emerald-700">最低</span>
                    ) : (
                      <span className={ratio < 1 ? 'text-emerald-700' : 'text-muted-foreground'}>
                        {(ratio * 100).toFixed(0)}%
                      </span>
                    )}
                  </td>
                  <td className="px-5 py-2">
                    {a.enabled ? (
                      <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                        enabled
                      </span>
                    ) : (
                      <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                        disabled
                      </span>
                    )}
                  </td>
                  <td className="px-5 py-2">
                    <div className="flex items-center justify-end gap-2">
                      <Link
                        href={`/aliases/${a.id}`}
                        className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                      >
                        编辑
                      </Link>
                      <ActionButton
                        action={toggleAliasEnabled}
                        args={[a.id]}
                        size="sm"
                        label={a.enabled ? '停用' : '启用'}
                        pendingLabel={a.enabled ? '停用中…' : '启用中…'}
                      />
                      <ActionButton
                        action={deleteAlias}
                        args={[a.id]}
                        size="sm"
                        variant="destructive"
                        label="删除"
                        pendingLabel="删除中…"
                        confirmText={`确定删除 ${a.llm_providers?.slug ?? 'provider'} 上 ${a.provider_model_id} 的 alias？`}
                      />
                    </div>
                  </td>
                </tr>
              );
            })}
        </tbody>
      </table>
    </section>
  );
}
