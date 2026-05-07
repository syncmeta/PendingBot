'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

export type ModelFormState = { error?: string };

const KNOWN_CAPS = ['vision', 'tool_use', 'prompt_cache', 'reasoning', 'json_mode'] as const;

function parseForm(formData: FormData) {
  const slug = String(formData.get('slug') ?? '').trim();
  const display_name = String(formData.get('display_name') ?? '').trim();
  const family = String(formData.get('family') ?? '').trim() || null;

  const ctxRaw = String(formData.get('context_window') ?? '').trim();
  const context_window = ctxRaw ? Number.parseInt(ctxRaw, 10) : null;
  const outRaw = String(formData.get('max_output_tokens') ?? '').trim();
  const max_output_tokens = outRaw ? Number.parseInt(outRaw, 10) : null;

  const enabled = formData.get('enabled') === 'on';
  const deprecated = formData.get('deprecated') === 'on';
  const notes = String(formData.get('notes') ?? '').trim() || null;

  if (!slug) return { error: 'slug 必填' };
  if (!display_name) return { error: 'display_name 必填' };
  if (context_window != null && (!Number.isFinite(context_window) || context_window <= 0)) {
    return { error: 'context_window 必须是正整数' };
  }
  if (max_output_tokens != null && (!Number.isFinite(max_output_tokens) || max_output_tokens <= 0)) {
    return { error: 'max_output_tokens 必须是正整数' };
  }

  const capabilities: Record<string, boolean> = {};
  for (const cap of KNOWN_CAPS) {
    capabilities[cap] = formData.get(`cap_${cap}`) === 'on';
  }

  return {
    row: {
      slug,
      display_name,
      family,
      context_window,
      max_output_tokens,
      capabilities,
      enabled,
      deprecated_at: deprecated ? new Date().toISOString() : null,
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
    target_kind: 'llm_model',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function createModel(
  _prev: ModelFormState,
  formData: FormData,
): Promise<ModelFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data, error } = await supa
    .from('llm_models')
    .insert(parsed.row as never)
    .select('id')
    .single();
  if (error) return { error: error.message };

  await audit({
    action: 'model.create',
    targetId: data.id,
    before: null,
    after: parsed.row,
    actorId: admin.id,
  });
  revalidatePath('/models');
  redirect('/models');
}

export async function updateModel(
  id: string,
  _prev: ModelFormState,
  formData: FormData,
): Promise<ModelFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_models')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa
    .from('llm_models')
    .update({ ...parsed.row, updated_at: new Date().toISOString() } as never)
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'model.update',
    targetId: id,
    before,
    after: parsed.row,
    actorId: admin.id,
  });
  revalidatePath('/models');
  redirect('/models');
}

export async function deleteModel(id: string) {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_models')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa.from('llm_models').delete().eq('id', id);
  if (error) return;

  await audit({
    action: 'model.delete',
    targetId: id,
    before,
    after: null,
    actorId: admin.id,
  });
  revalidatePath('/models');
}
