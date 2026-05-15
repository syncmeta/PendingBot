import { notFound } from 'next/navigation';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { McpServerForm } from '../_form';
import { updateMcpServer } from '../actions';

export default async function EditMcpServerPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;

  const supa = supabaseAdmin();
  const { data: row } = await supa
    .from('mcp_servers')
    .select(
      'id, name, url, transport, auth_kind, auth_header_name, secret_ref, enabled, notes',
    )
    .eq('id', id)
    .maybeSingle();
  if (!row) notFound();

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">编辑 MCP 服务</h1>
      <McpServerForm
        action={updateMcpServer.bind(null, id)}
        initial={row}
        submitLabel="保存"
      />
    </main>
  );
}
