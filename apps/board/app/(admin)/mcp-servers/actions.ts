'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { withFlash } from '@/components/toast-redirect';

// Server actions for the MCP servers admin page. Edge worker reads
// pendingbot.mcp_servers on a 60s isolate cache (see
// apps/edge/src/mcp/client.ts) — saved changes take effect within a
// minute, no deploy needed. Secrets continue to live in Cloudflare
// Workers Secrets; only the env-var name (`secret_ref`) lands here.

export type McpServerFormState = { error?: string };

const ALLOWED_TRANSPORT = ['http', 'sse'] as const;
const ALLOWED_AUTH = ['none', 'header'] as const;
type Transport = (typeof ALLOWED_TRANSPORT)[number];
type AuthKind = (typeof ALLOWED_AUTH)[number];

interface ParsedRow {
  name: string;
  url: string;
  transport: Transport;
  auth_kind: AuthKind;
  auth_header_name: string | null;
  secret_ref: string | null;
  enabled: boolean;
  notes: string | null;
}

function parseForm(formData: FormData): { row: ParsedRow } | { error: string } {
  const name = String(formData.get('name') ?? '').trim();
  const url = String(formData.get('url') ?? '').trim();
  const transport = String(formData.get('transport') ?? 'http') as Transport;
  const auth_kind = String(formData.get('auth_kind') ?? 'none') as AuthKind;
  const auth_header_name_raw = String(formData.get('auth_header_name') ?? '').trim();
  const secret_ref_raw = String(formData.get('secret_ref') ?? '').trim();
  const enabled = formData.get('enabled') === 'on';
  const notes = String(formData.get('notes') ?? '').trim() || null;

  if (!name) return { error: 'name 必填' };
  if (!/^[a-z0-9-]+$/.test(name)) return { error: 'name 只能小写字母 / 数字 / 短横线' };
  if (!url) return { error: 'url 必填' };
  if (!ALLOWED_TRANSPORT.includes(transport)) return { error: 'transport 不合法' };
  if (!ALLOWED_AUTH.includes(auth_kind)) return { error: 'auth_kind 不合法' };

  // Match the DB consistency constraint (mcp_servers_auth_consistency_chk)
  // so a bad submit surfaces a friendly error instead of a Postgres
  // check-constraint message.
  if (auth_kind === 'none' && (auth_header_name_raw || secret_ref_raw)) {
    return { error: "auth_kind='none' 时不要填 header / secret" };
  }
  if (auth_kind === 'header') {
    if (!auth_header_name_raw) return { error: "auth_kind='header' 时 auth_header_name 必填" };
    if (!secret_ref_raw) return { error: "auth_kind='header' 时 secret_ref 必填（Wrangler env var 名）" };
  }

  return {
    row: {
      name,
      url,
      transport,
      auth_kind,
      auth_header_name: auth_kind === 'header' ? auth_header_name_raw : null,
      secret_ref: auth_kind === 'header' ? secret_ref_raw : null,
      enabled,
      notes,
    },
  };
}

async function audit(args: {
  action: string;
  targetId: string;
  before: unknown;
  after: unknown;
  actorId: string;
}) {
  const supa = supabaseAdmin();
  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: args.actorId,
    action: args.action,
    target_kind: 'mcp_server',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function createMcpServer(
  _prev: McpServerFormState,
  formData: FormData,
): Promise<McpServerFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data, error } = await supa
    .from('mcp_servers')
    .insert(parsed.row)
    .select('id')
    .single();
  if (error) return { error: error.message };

  await audit({
    action: 'mcp_server.create',
    targetId: data.id,
    before: null,
    after: parsed.row,
    actorId: admin.id,
  });

  revalidatePath('/mcp-servers');
  redirect(withFlash('/mcp-servers', `已新增 MCP 服务 ${parsed.row.name}`));
}

export async function updateMcpServer(
  id: string,
  _prev: McpServerFormState,
  formData: FormData,
): Promise<McpServerFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('mcp_servers')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa
    .from('mcp_servers')
    .update({ ...parsed.row, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'mcp_server.update',
    targetId: id,
    before,
    after: parsed.row,
    actorId: admin.id,
  });

  revalidatePath('/mcp-servers');
  redirect(withFlash('/mcp-servers', `已保存 MCP 服务 ${parsed.row.name}`));
}

export type ActionResult = { ok?: true; error?: string; message?: string };

export async function toggleMcpServerEnabled(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('mcp_servers')
    .select('id, name, enabled')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'MCP 服务不存在' };

  const next = !before.enabled;
  const { error } = await supa
    .from('mcp_servers')
    .update({ enabled: next, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: next ? 'mcp_server.enable' : 'mcp_server.disable',
    targetId: id,
    before: { enabled: before.enabled },
    after: { enabled: next },
    actorId: admin.id,
  });

  revalidatePath('/mcp-servers');
  return { ok: true, message: next ? `已启用 ${before.name}` : `已停用 ${before.name}` };
}

export async function deleteMcpServer(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('mcp_servers')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'MCP 服务不存在' };

  const { error } = await supa.from('mcp_servers').delete().eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'mcp_server.delete',
    targetId: id,
    before,
    after: null,
    actorId: admin.id,
  });

  revalidatePath('/mcp-servers');
  return { ok: true, message: `已删除 ${before.name}` };
}
