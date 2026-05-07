import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { RuleForm, type ModelOption, type ProviderOption } from '../_form';
import { updateRule } from '../actions';

export default async function EditRulePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supa = supabaseAdmin();

  const [{ data: row }, { data: models }, { data: providers }] = await Promise.all([
    supa
      .from('task_routing_rules')
      .select(
        'id, task_type, match_priority, enabled, override_model_id, prefer_provider_id, notes',
      )
      .eq('id', id)
      .maybeSingle(),
    supa.from('llm_models').select('id, slug, display_name').order('slug'),
    supa.from('llm_providers').select('id, slug, display_name').order('priority'),
  ]);
  if (!row) notFound();

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">编辑路由规则</h1>
      <RuleForm
        action={updateRule.bind(null, id)}
        models={(models ?? []) as ModelOption[]}
        providers={(providers ?? []) as ProviderOption[]}
        submitLabel="保存"
        initial={row}
      />
    </main>
  );
}
