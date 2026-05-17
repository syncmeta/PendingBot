'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { withFlash } from '@/components/toast-redirect';

// Server actions for the Tools admin page. Edge worker reads
// pendingbot.tools on a 60s isolate cache and intersects its
// advertised tool list with enabled=true rows (see
// apps/edge/src/lib/tools-registry.ts). Saved changes take effect on
// the model surface within ~1 min, no deploy.

export type ActionResult = { ok?: true; error?: string; message?: string };
export type ToolFormState = { error?: string };

const ALLOWED_KIND = ['native', 'mcp'] as const;
const ALLOWED_SCOPE = ['chat', 'envelope'] as const;
type Kind = (typeof ALLOWED_KIND)[number];
type Scope = (typeof ALLOWED_SCOPE)[number];

interface ParsedRow {
  key: string;
  kind: Kind;
  mcp_server_id: string | null;
  scopes: Scope[];
  description: string | null;
  model_description: string | null;
  enabled: boolean;
  notes: string | null;
}

function parseForm(formData: FormData): { row: ParsedRow } | { error: string } {
  const key = String(formData.get('key') ?? '').trim();
  const kind = String(formData.get('kind') ?? 'native') as Kind;
  const mcp_server_id_raw = String(formData.get('mcp_server_id') ?? '').trim();
  const scopes = formData
    .getAll('scopes')
    .map((s) => String(s))
    .filter((s): s is Scope => (ALLOWED_SCOPE as readonly string[]).includes(s));
  const description = String(formData.get('description') ?? '').trim() || null;
  // model_description is the description the LLM actually sees. Required
  // for native tools (no code default); optional for MCP (NULL = upstream
  // server's own description). Only the ends are trimmed — interior
  // whitespace/newlines are meaningful.
  const model_description = String(formData.get('model_description') ?? '').trim() || null;
  const notes = String(formData.get('notes') ?? '').trim() || null;
  const enabled = formData.get('enabled') === 'on';

  if (!key) return { error: 'key 必填' };
  // Tool keys are the function.name the LLM sees — snake_case identifiers.
  if (!/^[a-z0-9_]+$/.test(key)) return { error: 'key 只能小写字母 / 数字 / 下划线' };
  if (!ALLOWED_KIND.includes(kind)) return { error: 'kind 不合法' };
  if (scopes.length === 0) return { error: '至少选一个 scope（chat / envelope）' };

  // Match the DB consistency constraint (tools_kind_consistency_chk) so a
  // bad submit surfaces a friendly error instead of a Postgres message.
  if (kind === 'native' && mcp_server_id_raw) {
    return { error: "kind='native' 时不要选 MCP server" };
  }
  if (kind === 'mcp' && !mcp_server_id_raw) {
    return { error: "kind='mcp' 时必须选一个 MCP server" };
  }
  // Native tools have no code-side default — the registry row IS the
  // model-facing description. Mirrors tools_native_model_description_chk.
  if (kind === 'native' && !model_description) {
    return { error: "kind='native' 时必须填模型描述" };
  }

  return {
    row: {
      key,
      kind,
      mcp_server_id: kind === 'mcp' ? mcp_server_id_raw : null,
      scopes,
      description,
      model_description,
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
    target_kind: 'tool',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function createTool(
  _prev: ToolFormState,
  formData: FormData,
): Promise<ToolFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data, error } = await supa
    .from('tools')
    .insert(parsed.row)
    .select('id')
    .single();
  if (error) {
    if (error.code === '23505') return { error: `工具 key "${parsed.row.key}" 已存在` };
    return { error: error.message };
  }

  await audit({
    action: 'tool.create',
    targetId: data.id,
    before: null,
    after: parsed.row,
    actorId: admin.id,
  });

  revalidatePath('/tools');
  redirect(withFlash('/tools', `已新增工具 ${parsed.row.key}`));
}

export async function updateTool(
  id: string,
  _prev: ToolFormState,
  formData: FormData,
): Promise<ToolFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('tools')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa
    .from('tools')
    .update({ ...parsed.row, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) {
    if (error.code === '23505') return { error: `工具 key "${parsed.row.key}" 已存在` };
    return { error: error.message };
  }

  await audit({
    action: 'tool.update',
    targetId: id,
    before,
    after: parsed.row,
    actorId: admin.id,
  });

  revalidatePath('/tools');
  redirect(withFlash('/tools', `已保存工具 ${parsed.row.key}`));
}

/**
 * Inline save for just the model-facing description, used by the Tools
 * list page so each tool's description can be browsed + edited without
 * opening the full edit form. For MCP tools an empty string clears the
 * value so the edge runtime falls back to the upstream server's
 * description; native tools reject an empty value — the registry row is
 * their single source of truth.
 */
export async function updateToolModelDescription(
  id: string,
  value: string,
): Promise<ActionResult> {
  const admin = await requireAdmin();
  const next = value.trim() || null;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('tools')
    .select('id, key, kind, model_description')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: '工具不存在' };
  if (next === null && before.kind === 'native') {
    return { error: `${before.key} 是 native 工具，模型描述不能清空` };
  }

  const { error } = await supa
    .from('tools')
    .update({ model_description: next, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'tool.update',
    targetId: id,
    before: { model_description: before.model_description },
    after: { model_description: next },
    actorId: admin.id,
  });

  revalidatePath('/tools');
  return {
    ok: true,
    message: next ? `已保存 ${before.key} 的模型描述` : `已清空 ${before.key} 的模型描述`,
  };
}

export async function toggleToolEnabled(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('tools')
    .select('id, key, enabled')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: '工具不存在' };

  const next = !before.enabled;
  const { error } = await supa
    .from('tools')
    .update({ enabled: next, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: next ? 'tool.enable' : 'tool.disable',
    targetId: id,
    before: { enabled: before.enabled },
    after: { enabled: next },
    actorId: admin.id,
  });

  revalidatePath('/tools');
  return { ok: true, message: next ? `已启用 ${before.key}` : `已停用 ${before.key}` };
}

export async function deleteTool(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('tools')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: '工具不存在' };

  const { error } = await supa.from('tools').delete().eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'tool.delete',
    targetId: id,
    before,
    after: null,
    actorId: admin.id,
  });

  revalidatePath('/tools');
  return { ok: true, message: `已删除 ${before.key}` };
}
