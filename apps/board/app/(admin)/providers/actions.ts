'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

export type ProviderFormState = { error?: string };

const ALLOWED_AUTH = ['bearer', 'header-x-api-key'] as const;
type AuthType = (typeof ALLOWED_AUTH)[number];

function parseForm(formData: FormData) {
  const slug = String(formData.get('slug') ?? '').trim();
  const display_name = String(formData.get('display_name') ?? '').trim();
  const base_url = String(formData.get('base_url') ?? '').trim();
  const auth_type = String(formData.get('auth_type') ?? 'bearer') as AuthType;
  const secret_ref = String(formData.get('secret_ref') ?? '').trim();
  const enabled = formData.get('enabled') === 'on';
  const priorityRaw = String(formData.get('priority') ?? '100');
  const priority = Number.parseInt(priorityRaw, 10);
  const notes = String(formData.get('notes') ?? '').trim() || null;

  if (!slug) return { error: 'slug 必填' };
  if (!display_name) return { error: 'display_name 必填' };
  if (!base_url) return { error: 'base_url 必填' };
  if (!secret_ref) return { error: 'secret_ref 必填（Wrangler env var 名）' };
  if (!ALLOWED_AUTH.includes(auth_type)) return { error: 'auth_type 不合法' };
  if (!Number.isFinite(priority)) return { error: 'priority 必须是数字' };
  return {
    row: { slug, display_name, base_url, auth_type, secret_ref, enabled, priority, notes },
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
    target_kind: 'llm_provider',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function createProvider(
  _prev: ProviderFormState,
  formData: FormData,
): Promise<ProviderFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data, error } = await supa
    .from('llm_providers')
    .insert(parsed.row)
    .select('id')
    .single();
  if (error) return { error: error.message };

  await audit({
    action: 'provider.create',
    targetId: data.id,
    before: null,
    after: parsed.row,
    actorId: admin.id,
  });

  revalidatePath('/providers');
  redirect('/providers');
}

export async function updateProvider(
  id: string,
  _prev: ProviderFormState,
  formData: FormData,
): Promise<ProviderFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_providers')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa
    .from('llm_providers')
    .update({ ...parsed.row, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'provider.update',
    targetId: id,
    before,
    after: parsed.row,
    actorId: admin.id,
  });

  revalidatePath('/providers');
  redirect('/providers');
}

export type ActionResult = { ok?: true; error?: string; message?: string };

export async function toggleProviderEnabled(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_providers')
    .select('id, slug, enabled')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'provider 不存在' };

  const next = !before.enabled;
  const { error } = await supa
    .from('llm_providers')
    .update({ enabled: next, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: next ? 'provider.enable' : 'provider.disable',
    targetId: id,
    before: { enabled: before.enabled },
    after: { enabled: next },
    actorId: admin.id,
  });

  revalidatePath('/providers');
  return { ok: true, message: next ? `已启用 ${before.slug}` : `已停用 ${before.slug}` };
}

export async function deleteProvider(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_providers')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'provider 不存在' };

  // Hard delete cascades to llm_model_aliases. Don't allow it for the
  // OpenRouter row by accident — that's the fallback path's anchor.
  if (before.slug === 'openrouter') return { error: 'OpenRouter 是 fallback 锚点,不允许删除（可停用）' };

  const { error } = await supa.from('llm_providers').delete().eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'provider.delete',
    targetId: id,
    before,
    after: null,
    actorId: admin.id,
  });

  revalidatePath('/providers');
  return { ok: true, message: `已删除 ${before.slug}` };
}
