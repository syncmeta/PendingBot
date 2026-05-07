import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { ProviderForm } from '../_form';
import { updateProvider, type ProviderFormState } from '../actions';

export default async function EditProviderPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;

  const supa = supabaseAdmin();
  const { data: row } = await supa
    .from('llm_providers')
    .select('id, slug, display_name, base_url, auth_type, secret_ref, enabled, priority, notes')
    .eq('id', id)
    .maybeSingle();
  if (!row) notFound();

  const action = async (prev: ProviderFormState, formData: FormData) =>
    updateProvider(id, prev, formData);

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">编辑 provider</h1>
      <ProviderForm
        action={action}
        initial={row}
        submitLabel="保存"
        // OpenRouter slug is the fallback path's anchor; allow editing
        // other fields but pin the slug so resolveRoute() keeps finding it.
        lockedSlug={row.slug === 'openrouter'}
      />
    </main>
  );
}
