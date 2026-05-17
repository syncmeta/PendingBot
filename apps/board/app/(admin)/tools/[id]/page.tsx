import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { ToolForm } from '../_form';
import { updateTool } from '../actions';

function asScopes(v: unknown): string[] {
  return Array.isArray(v) ? (v as unknown[]).filter((s): s is string => typeof s === 'string') : [];
}

export default async function EditToolPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;

  const supa = supabaseAdmin();
  const [{ data: row }, { data: servers }] = await Promise.all([
    supa
      .from('tools')
      .select('id, key, kind, mcp_server_id, scopes, description, model_description, enabled, notes')
      .eq('id', id)
      .maybeSingle(),
    supa.from('mcp_servers').select('id, name').order('name', { ascending: true }),
  ]);
  if (!row) notFound();

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">编辑工具</h1>
      <ToolForm
        action={updateTool.bind(null, id)}
        initial={{ ...row, scopes: asScopes(row.scopes) }}
        servers={servers ?? []}
        submitLabel="保存"
      />
    </main>
  );
}
