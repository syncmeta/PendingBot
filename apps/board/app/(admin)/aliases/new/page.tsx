import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { AliasForm, type ModelOption, type ProviderOption } from '../_form';
import { createAlias } from '../actions';

export default async function NewAliasPage({
  searchParams,
}: {
  searchParams: Promise<{ model_id?: string; provider_id?: string }>;
}) {
  const params = await searchParams;
  const supa = supabaseAdmin();

  const [{ data: models }, { data: providers }] = await Promise.all([
    supa
      .from('llm_models')
      .select('id, slug, display_name')
      .eq('enabled', true)
      .order('slug'),
    supa
      .from('llm_providers')
      .select('id, slug, display_name')
      .eq('enabled', true)
      .order('priority'),
  ]);

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">新增 alias</h1>

      {(models ?? []).length === 0 || (providers ?? []).length === 0 ? (
        <div className="rounded-lg border bg-card p-6 text-sm">
          <p className="font-medium">缺前置：</p>
          <ul className="mt-2 list-disc pl-6 text-muted-foreground">
            {(models ?? []).length === 0 && (
              <li>
                还没有 enabled 的 canonical model — 先去{' '}
                <Link href="/models/new" className="underline">
                  /models/new
                </Link>{' '}
                创一个
              </li>
            )}
            {(providers ?? []).length === 0 && (
              <li>
                还没有 enabled 的 provider — 先去{' '}
                <Link href="/providers/new" className="underline">
                  /providers/new
                </Link>{' '}
                配一个
              </li>
            )}
          </ul>
        </div>
      ) : (
        <AliasForm
          action={createAlias}
          models={(models ?? []) as ModelOption[]}
          providers={(providers ?? []) as ProviderOption[]}
          submitLabel="创建"
          initial={{
            model_id: params.model_id,
            provider_id: params.provider_id,
            weight: 100,
            enabled: true,
          }}
        />
      )}
    </main>
  );
}
