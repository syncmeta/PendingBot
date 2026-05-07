import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { AliasForm, type ModelOption, type ProviderOption } from '../_form';
import { updateAlias, type AliasFormState } from '../actions';

export default async function EditAliasPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supa = supabaseAdmin();

  const { data: row } = await supa
    .from('llm_model_aliases')
    .select(
      'id, model_id, provider_id, provider_model_id, enabled, weight, input_price, cached_input_price, output_price, cache_write_price, notes',
    )
    .eq('id', id)
    .maybeSingle();
  if (!row) notFound();

  const [{ data: models }, { data: providers }] = await Promise.all([
    supa
      .from('llm_models')
      .select('id, slug, display_name')
      .order('slug'),
    supa
      .from('llm_providers')
      .select('id, slug, display_name')
      .order('priority'),
  ]);

  const action = async (prev: AliasFormState, formData: FormData) =>
    updateAlias(id, prev, formData);

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">编辑 alias</h1>
      <AliasForm
        action={action}
        models={(models ?? []) as ModelOption[]}
        providers={(providers ?? []) as ProviderOption[]}
        submitLabel="保存"
        initial={row}
        // (model_id, provider_id) is the unique key — let edit change
        // prices/weight/passthrough id but not the pair itself, otherwise
        // it's effectively a new alias and a delete+create is clearer.
        modelLocked
        providerLocked
      />
    </main>
  );
}
