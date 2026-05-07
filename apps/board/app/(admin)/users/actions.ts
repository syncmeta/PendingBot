'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

export type QuotaFormState = { error?: string };

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
    target_kind: 'user',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function updateQuota(
  userId: string,
  _prev: QuotaFormState,
  formData: FormData,
): Promise<QuotaFormState> {
  const admin = await requireAdmin();
  const dailyRaw = String(formData.get('daily_limit_usd') ?? '').trim();
  const monthlyRaw = String(formData.get('monthly_limit_usd') ?? '').trim();
  const daily = Number.parseFloat(dailyRaw);
  const monthly = Number.parseFloat(monthlyRaw);
  if (!Number.isFinite(daily) || daily < 0) return { error: 'daily_limit_usd 必须是非负数' };
  if (!Number.isFinite(monthly) || monthly < 0) return { error: 'monthly_limit_usd 必须是非负数' };

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('user_quota')
    .select('*')
    .eq('user_id', userId)
    .maybeSingle();

  const next = {
    user_id: userId,
    daily_limit_usd: daily,
    monthly_limit_usd: monthly,
    updated_at: new Date().toISOString(),
  };

  // Upsert because new users may not have a quota row yet — we don't
  // create one on signup, the admin opting them into a different
  // limit is what materialises the row.
  const { error } = await supa
    .from('user_quota')
    .upsert(next, { onConflict: 'user_id' });
  if (error) return { error: error.message };

  await audit({
    action: 'user_quota.update',
    targetId: userId,
    before,
    after: next,
    actorId: admin.id,
  });
  revalidatePath('/users');
  redirect('/users');
}

export async function resetQuotaUsed(userId: string) {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('user_quota')
    .select('daily_used_usd, monthly_used_usd')
    .eq('user_id', userId)
    .maybeSingle();
  if (!before) return;

  await supa
    .from('user_quota')
    .update({
      daily_used_usd: 0,
      monthly_used_usd: 0,
      updated_at: new Date().toISOString(),
    })
    .eq('user_id', userId);

  await audit({
    action: 'user_quota.reset_used',
    targetId: userId,
    before,
    after: { daily_used_usd: 0, monthly_used_usd: 0 },
    actorId: admin.id,
  });
  revalidatePath('/users');
}

export async function toggleAdmin(userId: string) {
  const admin = await requireAdmin();
  // Don't let an admin demote themselves through the UI — easy way to
  // lock everyone out; force a SQL-level escape hatch for that case.
  if (userId === admin.id) return;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('users')
    .select('id, is_admin')
    .eq('id', userId)
    .maybeSingle();
  if (!before) return;

  const next = !before.is_admin;
  await supa
    .from('users')
    .update({ is_admin: next, updated_at: new Date().toISOString() })
    .eq('id', userId);

  await audit({
    action: next ? 'user.grant_admin' : 'user.revoke_admin',
    targetId: userId,
    before: { is_admin: before.is_admin },
    after: { is_admin: next },
    actorId: admin.id,
  });
  revalidatePath('/users');
}
