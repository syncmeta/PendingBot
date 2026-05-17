import { supabaseAdmin } from '@/lib/supabase/admin';
import { ToolForm } from '../_form';
import { createTool } from '../actions';

export default async function NewToolPage() {
  const supa = supabaseAdmin();
  const { data: servers } = await supa
    .from('mcp_servers')
    .select('id, name')
    .order('name', { ascending: true });

  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">新增工具</h1>
      <ToolForm action={createTool} servers={servers ?? []} submitLabel="创建" />
    </main>
  );
}
