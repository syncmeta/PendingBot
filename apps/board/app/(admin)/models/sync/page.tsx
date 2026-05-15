import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { ActionButton } from '@/components/action-button';
import { fmtTokens } from '@/lib/format';
import { fetchOpenRouterSpecs, type OpenRouterSpec } from '@/lib/openrouter-spec';
import { syncOneModel } from './actions';

// Sync canonical model metadata from OpenRouter. Per-row Apply rather
// than a bulk-checkbox flow — the surface area is small (only models
// with openrouter_canonical_slug set) and admins want to see exactly
// which fields change before clicking. Pricing lives in
// /aliases/upstream; this page is intentionally pricing-free.

export const dynamic = 'force-dynamic';

interface FieldDiff<T> {
  current: T;
  upstream: T;
  changed: boolean;
}

export default async function ModelsSyncPage() {
  const supa = supabaseAdmin();

  const { data: models } = await supa
    .from('llm_models')
    .select(
      'id, slug, display_name, context_window, max_output_tokens, capabilities, openrouter_canonical_slug',
    )
    .not('openrouter_canonical_slug', 'is', null)
    .order('slug');

  let specs: Map<string, OpenRouterSpec> | null = null;
  let fetchError: string | null = null;
  try {
    specs = await fetchOpenRouterSpecs();
  } catch (err) {
    fetchError = err instanceof Error ? err.message : String(err);
  }

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-end justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">从 OpenRouter 同步模型信息</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            把 context_window / max_output_tokens / capabilities 以 OpenRouter
            为准刷新到本地。display_name 仅在本地为空时回填，避免覆盖人工命名。
            价格不在这里同步——去 <Link href="/aliases/upstream" className="underline">/aliases/upstream</Link>。
          </p>
        </div>
      </header>

      {fetchError && (
        <div className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          拉 OpenRouter 失败：{fetchError}
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">slug</th>
              <th className="px-4 py-2 font-medium">openrouter id</th>
              <th className="px-4 py-2 font-medium text-right">ctx</th>
              <th className="px-4 py-2 font-medium text-right">max out</th>
              <th className="px-4 py-2 font-medium">caps</th>
              <th className="px-4 py-2" />
            </tr>
          </thead>
          <tbody>
            {(models ?? []).map((m) => {
              const spec = specs?.get(m.openrouter_canonical_slug!);
              if (!spec) {
                return (
                  <tr key={m.id} className="border-b last:border-0">
                    <td className="px-4 py-2 font-mono text-xs">{m.slug}</td>
                    <td className="px-4 py-2 font-mono text-xs">
                      {m.openrouter_canonical_slug}
                    </td>
                    <td colSpan={3} className="px-4 py-2 text-muted-foreground">
                      {specs == null
                        ? '未拉取'
                        : `OpenRouter catalog 没有 ${m.openrouter_canonical_slug}`}
                    </td>
                    <td className="px-4 py-2" />
                  </tr>
                );
              }
              const currentCaps = (m.capabilities ?? {}) as Record<string, boolean>;
              const diffs = {
                ctx: diff(m.context_window as number | null, spec.contextLength),
                maxOut: diff(
                  m.max_output_tokens as number | null,
                  spec.maxCompletionTokens,
                ),
                caps: capsDiff(currentCaps, spec.capabilities),
              };
              const anyChange =
                diffs.ctx.changed || diffs.maxOut.changed || diffs.caps.length > 0;
              return (
                <tr key={m.id} className="border-b last:border-0 align-top">
                  <td className="px-4 py-2 font-mono text-xs">{m.slug}</td>
                  <td className="px-4 py-2 font-mono text-xs">
                    {m.openrouter_canonical_slug}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <DiffCell
                      current={fmtTokens(diffs.ctx.current)}
                      upstream={fmtTokens(diffs.ctx.upstream)}
                      changed={diffs.ctx.changed}
                    />
                  </td>
                  <td className="px-4 py-2 text-right">
                    <DiffCell
                      current={fmtTokens(diffs.maxOut.current)}
                      upstream={fmtTokens(diffs.maxOut.upstream)}
                      changed={diffs.maxOut.changed}
                    />
                  </td>
                  <td className="px-4 py-2">
                    {diffs.caps.length === 0 ? (
                      <span className="text-muted-foreground">—</span>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {diffs.caps.map((c) => (
                          <span
                            key={c.key}
                            className={`rounded px-1.5 py-0.5 text-xs ${
                              c.upstream
                                ? 'bg-emerald-100 text-emerald-800'
                                : 'bg-amber-100 text-amber-800'
                            }`}
                            title={`本地 ${c.current ? '✓' : '—'} → OR ${c.upstream ? '✓' : '—'}`}
                          >
                            {c.upstream ? '+' : '−'}
                            {c.key}
                          </span>
                        ))}
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <ActionButton
                      action={syncOneModel}
                      args={[m.id]}
                      size="sm"
                      variant={anyChange ? 'primary' : 'normal'}
                      label={anyChange ? 'Apply' : 'No-op'}
                      pendingLabel="同步中…"
                    />
                  </td>
                </tr>
              );
            })}
            {(models ?? []).length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                  还没有 model 配置 openrouter_canonical_slug。去 <Link href="/models" className="underline">/models</Link> 编辑一行，填上 OpenRouter id（如
                  anthropic/claude-haiku-4.5）后回来同步。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </main>
  );
}

function diff<T>(current: T, upstream: T): FieldDiff<T> {
  return { current, upstream, changed: current !== upstream };
}

interface CapDiffRow {
  key: string;
  current: boolean;
  upstream: boolean;
}

function capsDiff(
  current: Record<string, boolean>,
  upstream: Record<string, boolean>,
): CapDiffRow[] {
  const keys = new Set([...Object.keys(current), ...Object.keys(upstream)]);
  const out: CapDiffRow[] = [];
  for (const k of keys) {
    const c = current[k] === true;
    const u = upstream[k] === true;
    if (c !== u) out.push({ key: k, current: c, upstream: u });
  }
  return out;
}

function DiffCell({
  current,
  upstream,
  changed,
}: {
  current: React.ReactNode;
  upstream: React.ReactNode;
  changed: boolean;
}) {
  if (!changed) {
    return <span className="tabular-nums text-muted-foreground">{current}</span>;
  }
  return (
    <span className="tabular-nums">
      <span className="text-muted-foreground line-through">{current}</span>
      <span className="ml-2 font-medium text-emerald-700">{upstream}</span>
    </span>
  );
}
