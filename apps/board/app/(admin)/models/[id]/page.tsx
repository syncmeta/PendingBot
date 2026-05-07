import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { ModelForm } from '../_form';
import { updateModel } from '../actions';

export default async function EditModelPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supa = supabaseAdmin();

  const { data: row } = await supa
    .from('llm_models')
    .select(
      'id, slug, family, display_name, context_window, max_output_tokens, capabilities, enabled, deprecated_at, notes',
    )
    .eq('id', id)
    .maybeSingle();
  if (!row) notFound();

  const { data: aliases } = await supa
    .from('llm_model_aliases')
    .select('id, provider_model_id, weight, enabled, llm_providers(slug, display_name)')
    .eq('model_id', id);

  return (
    <main className="container max-w-2xl py-10 space-y-8">
      <h1 className="text-2xl font-bold tracking-tight">编辑 model</h1>
      <ModelForm
        action={updateModel.bind(null, id)}
        initial={{
          slug: row.slug,
          display_name: row.display_name,
          family: row.family,
          context_window: row.context_window,
          max_output_tokens: row.max_output_tokens,
          capabilities: row.capabilities as Record<string, unknown>,
          enabled: row.enabled,
          deprecated_at: row.deprecated_at,
          notes: row.notes,
        }}
        submitLabel="保存"
      />

      <section>
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-medium">这个 model 的 aliases</h2>
          <Link
            href={`/aliases/new?model_id=${id}`}
            className="text-xs underline"
          >
            新增 alias →
          </Link>
        </div>
        <div className="mt-3 overflow-x-auto rounded-lg border bg-card">
          <table className="w-full text-sm">
            <thead className="border-b text-left text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">provider</th>
                <th className="px-4 py-2 font-medium">provider_model_id</th>
                <th className="px-4 py-2 font-medium text-right">weight</th>
                <th className="px-4 py-2 font-medium">enabled</th>
              </tr>
            </thead>
            <tbody>
              {(aliases ?? []).map((a) => (
                <tr key={a.id} className="border-b last:border-0">
                  <td className="px-4 py-2">
                    {a.llm_providers?.display_name ?? a.llm_providers?.slug ?? '—'}
                  </td>
                  <td className="px-4 py-2 font-mono text-xs">{a.provider_model_id}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{a.weight}</td>
                  <td className="px-4 py-2">{a.enabled ? '✓' : '—'}</td>
                </tr>
              ))}
              {(aliases ?? []).length === 0 && (
                <tr>
                  <td colSpan={4} className="px-4 py-6 text-center text-muted-foreground">
                    还没有 alias。
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
