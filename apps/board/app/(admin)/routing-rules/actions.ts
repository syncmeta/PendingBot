'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { withFlash } from '@/components/toast';

export type RuleFormState = { error?: string };

function parseForm(formData: FormData) {
  const task_type = String(formData.get('task_type') ?? '').trim();
  const priorityRaw = String(formData.get('match_priority') ?? '100');
  const match_priority = Number.parseInt(priorityRaw, 10);
  const enabled = formData.get('enabled') === 'on';
  const overrideRaw = String(formData.get('override_model_id') ?? '').trim();
  const preferRaw = String(formData.get('prefer_provider_id') ?? '').trim();
  const notes = String(formData.get('notes') ?? '').trim() || null;

  if (!task_type) return { error: 'task_type 必填' };
  if (!Number.isFinite(match_priority) || match_priority < 0) {
    return { error: 'match_priority 必须是非负整数' };
  }
  return {
    row: {
      task_type,
      match_priority,
      enabled,
      override_model_id: overrideRaw || null,
      prefer_provider_id: preferRaw || null,
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
    target_kind: 'task_routing_rule',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function createRule(
  _prev: RuleFormState,
  formData: FormData,
): Promise<RuleFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data, error } = await supa
    .from('task_routing_rules')
    .insert(parsed.row)
    .select('id')
    .single();
  if (error) return { error: error.message };

  await audit({
    action: 'routing_rule.create',
    targetId: data.id,
    before: null,
    after: parsed.row,
    actorId: admin.id,
  });
  revalidatePath('/routing-rules');
  redirect(withFlash('/routing-rules', `已新增 rule (task=${parsed.row.task_type})`));
}

export async function updateRule(
  id: string,
  _prev: RuleFormState,
  formData: FormData,
): Promise<RuleFormState> {
  const admin = await requireAdmin();
  const parsed = parseForm(formData);
  if ('error' in parsed) return parsed;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('task_routing_rules')
    .select('*')
    .eq('id', id)
    .maybeSingle();

  const { error } = await supa
    .from('task_routing_rules')
    .update({ ...parsed.row, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'routing_rule.update',
    targetId: id,
    before,
    after: parsed.row,
    actorId: admin.id,
  });
  revalidatePath('/routing-rules');
  redirect(withFlash('/routing-rules', `已保存 rule (task=${parsed.row.task_type})`));
}

export type ActionResult = { ok?: true; error?: string; message?: string };

export async function toggleRuleEnabled(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('task_routing_rules')
    .select('id, enabled')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'routing rule 不存在' };

  const next = !before.enabled;
  const { error } = await supa
    .from('task_routing_rules')
    .update({ enabled: next, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: next ? 'routing_rule.enable' : 'routing_rule.disable',
    targetId: id,
    before: { enabled: before.enabled },
    after: { enabled: next },
    actorId: admin.id,
  });
  revalidatePath('/routing-rules');
  return { ok: true, message: next ? '已启用 rule' : '已停用 rule' };
}

export async function deleteRule(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('task_routing_rules')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: 'routing rule 不存在' };

  const { error } = await supa.from('task_routing_rules').delete().eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'routing_rule.delete',
    targetId: id,
    before,
    after: null,
    actorId: admin.id,
  });
  revalidatePath('/routing-rules');
  return { ok: true, message: '已删除 rule' };
}
