'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { withFlash } from '@/components/toast-redirect';

export type AliasFormState = { error?: string };

function parsePrice(formData: FormData, key: string): number | null | { error: string } {
  const raw = String(formData.get(key) ?? '').trim();
  if (!raw) return null;
  const v = Number.parseFloat(raw);
  if (!Number.isFinite(v) || v < 0) return { error: `${key} 必须是非负数` };
  return v;
}

function parseForm(formData: FormData) {
  const model_id = String(formData.get('model_id') ?? '').trim();
  const provider_id = String(formData.get('provider_id') ?? '').trim();
  const provider_model_id = String(formData.get('provider_model_id') ?? '').trim();
  const enabled = formData.get('enabled') === 'on';
  const weightRaw = String(formData.get('weight') ?? '100').trim();
  const weight = Number.parseInt(weightRaw, 10);
  const notes = String(formData.get('notes') ?? '').trim() || null;

  if (!model_id) return { error: 'model 必选' };
  if (!provider_id) return { error: 'provider 必选' };
  if (!provider_model_id) {
    return {
      error:
        'provider_model_id 必填（该 provider 自己用的 model 字符串，比如 anthropic/claude-opus-4.5 或 claude-opus-4-5-20251022）',
    };
  }
  if (!Number.isFinite(weight) || weight < 0) return { error: 'weight 必须是非负整数' };

  const input = parsePrice(formData, 'input_price');
  if (input != null && typeof input === 'object') return input;
  const cachedInput = parsePrice(formData, 'cached_input_price');
  if (cachedInput != null && typeof cachedInput === 'object') return cachedInput;
  const output = parsePrice(formData, 'output_price');
  if (output != null && typeof output === 'object') return output;
  const cacheWrite = parsePrice(formData, 'cache_write_price');
  if (cacheWrite != null && typeof cacheWrite === 'object') return cacheWrite;
  // Voice-call dims — both optional, populated on the OpenAI Realtime
  // alias and null elsewhere. Aliases without these don't bill audio.
  const audioInput = parsePrice(formData, 'audio_input_price');
  if (audioInput != null && typeof audioInput === 'object') return audioInput;
  const audioOutput = parsePrice(formData, 'audio_output_price');
  if (audioOutput != null && typeof audioOutput === 'object') return audioOutput;

  if (input == null) return { error: 'input_price 必填' };
  if (output == null) return { error: 'output_price 必填' };

  return {
    row: {
      model_id,
      provider_id,
      provider_model_id,
      enabled,
      weight,
      input_price: input as number,
      cached_input_price: cachedInput as number | null,
      output_price: output as number,
      cache_write_price: cacheWrite as number | null,
      audio_input_price: audioInput as number | null,
      audio_output_price: audioOutput as number | null,
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
    target_kind: 'llm_model_alias',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function createAlias(
  _prev: AliasFormState,
  formData: FormData,
): Promise<AliasFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data, error } = await supa
    .from('llm_model_aliases')
    .insert(parsed.row)
    .select('id')
    .single();
  if (error) return { error: error.message };

  await audit({
    action: 'alias.create',
    targetId: data.id,
    before: null,
    after: parsed.row,
    actorId: admin.id,
  });
  revalidatePath('/aliases');
  redirect(withFlash('/aliases', '已新增 alias'));
}

export async function updateAlias(
  id: string,
  _prev: AliasFormState,
  formData: FormData,
): Promise<AliasFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_model_aliases')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa
    .from('llm_model_aliases')
    .update({ ...parsed.row, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'alias.update',
    targetId: id,
    before,
    after: parsed.row,
    actorId: admin.id,
  });
  revalidatePath('/aliases');
  redirect(withFlash('/aliases', '已保存 alias'));
}

export type ActionResult = { ok?: true; error?: string; message?: string };

export async function toggleAliasEnabled(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_model_aliases')
    .select('id, enabled')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'alias 不存在' };

  const next = !before.enabled;
  const { error } = await supa
    .from('llm_model_aliases')
    .update({ enabled: next, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: next ? 'alias.enable' : 'alias.disable',
    targetId: id,
    before: { enabled: before.enabled },
    after: { enabled: next },
    actorId: admin.id,
  });
  revalidatePath('/aliases');
  return { ok: true, message: next ? '已启用 alias' : '已停用 alias' };
}

export async function deleteAlias(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('llm_model_aliases')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'alias 不存在' };

  const { error } = await supa.from('llm_model_aliases').delete().eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'alias.delete',
    targetId: id,
    before,
    after: null,
    actorId: admin.id,
  });
  revalidatePath('/aliases');
  return { ok: true, message: '已删除 alias' };
}
