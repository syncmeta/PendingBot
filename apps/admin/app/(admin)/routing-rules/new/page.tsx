import { supabaseAdmin } from '@/lib/supabase/admin';
import { RuleForm, type ModelOption, type ProviderOption } from '../_form';
import { createRule } from '../actions';

export default async function NewRulePage() {
  const supa = supabaseAdmin();
  const [{ data: models }, { data: providers }] = await Promise.all([
    supa.from('llm_models').select('id, slug, display_name').order('slug'),
    supa.from('llm_providers').select('id, slug, display_name').order('priority'),
  ]);

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">新增路由规则</h1>
      <RuleForm
        action={createRule}
        models={(models ?? []) as ModelOption[]}
        providers={(providers ?? []) as ProviderOption[]}
        submitLabel="创建"
        initial={{ match_priority: 100, enabled: true }}
      />
    </main>
  );
}
