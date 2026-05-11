'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { withFlash } from '@/components/toast';

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
  redirect(withFlash('/users', '已保存配额'));
}

export async function resetQuotaUsed(
  userId: string,
): Promise<DeletionActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('user_quota')
    .select('daily_used_usd, monthly_used_usd')
    .eq('user_id', userId)
    .maybeSingle();
  if (!before) return { error: '该用户还没有 user_quota 行,无需重置' };

  const { error } = await supa
    .from('user_quota')
    .update({
      daily_used_usd: 0,
      monthly_used_usd: 0,
      updated_at: new Date().toISOString(),
    })
    .eq('user_id', userId);
  if (error) return { error: error.message };

  await audit({
    action: 'user_quota.reset_used',
    targetId: userId,
    before,
    after: { daily_used_usd: 0, monthly_used_usd: 0 },
    actorId: admin.id,
  });
  revalidatePath('/users');
  return { ok: true, message: '已重置 daily / monthly 用量' };
}

export type GrantFormState = { error?: string; ok?: { credits: number; new_balance: number } };

export async function grantCredits(
  userId: string,
  _prev: GrantFormState,
  formData: FormData,
): Promise<GrantFormState> {
  const admin = await requireAdmin();
  const creditsRaw = String(formData.get('credits') ?? '').trim();
  const reason = String(formData.get('reason') ?? '').trim() || null;
  const credits = Number.parseInt(creditsRaw, 10);
  if (!Number.isFinite(credits) || credits === 0) {
    return { error: 'credits 必须是非零整数（正数=发放，负数=扣回）' };
  }

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('users')
    .select('balance_credits')
    .eq('id', userId)
    .maybeSingle();

  const { data: newBalance, error } = await supa.rpc('billing_admin_grant', {
    p_user_id: userId,
    p_credits: credits,
    p_reason: reason ?? undefined,
  });
  if (error) return { error: error.message };

  await audit({
    action: credits > 0 ? 'billing.grant' : 'billing.adjust',
    targetId: userId,
    before: { balance_credits: before?.balance_credits ?? null },
    after: { balance_credits: newBalance, delta: credits, reason },
    actorId: admin.id,
  });
  revalidatePath(`/users/${userId}`);
  revalidatePath('/billing');
  return { ok: { credits, new_balance: Number(newBalance ?? 0) } };
}

export type DeletionActionResult = { ok?: true; error?: string; message?: string };

/// Force-finalize a user's account, bypassing the 28-day cooldown. Calls
/// finalize_account_deletion(p_uid, p_force=true) which:
///   • logs the user's stored sentiment to account_deletion_log (if any),
///   • runs _delete_account_internal (cascading wipe + auth.users delete).
///
/// Returns the result instead of redirecting — the client wrapper alerts
/// on error and navigates on success. (Older revisions swallowed the RPC
/// error silently: the button just looked dead.)
export async function forceDeleteAccount(
  userId: string,
): Promise<DeletionActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();

  const { data: before } = await supa
    .from('users')
    .select('id, email, display_name, pending_deletion_at, pending_deletion_sentiment')
    .eq('id', userId)
    .maybeSingle();
  if (!before) return { error: '用户不存在' };

  const { error } = await supa.rpc('finalize_account_deletion', {
    p_uid: userId,
    p_force: true,
  });
  if (error) {
    await audit({
      action: 'user.force_delete_failed',
      targetId: userId,
      before,
      after: { error: error.message },
      actorId: admin.id,
    });
    return { error: error.message };
  }

  await audit({
    action: 'user.force_delete',
    targetId: userId,
    before,
    after: null,
    actorId: admin.id,
  });
  revalidatePath('/users');
  return { ok: true };
}

/// Clear a user's pending-deletion tombstone from the board. Mostly an
/// escape hatch: the user normally cancels their own tombstone by
/// signing back in, but support might need to do it on their behalf.
export async function cancelPendingDeletion(
  userId: string,
): Promise<DeletionActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('users')
    .select('pending_deletion_at, pending_deletion_sentiment')
    .eq('id', userId)
    .maybeSingle();
  if (!before?.pending_deletion_at) return { error: '该用户没有待注销标记' };

  const { error } = await supa
    .from('users')
    .update({
      pending_deletion_at: null,
      pending_deletion_sentiment: null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', userId);
  if (error) return { error: error.message };

  await audit({
    action: 'user.cancel_pending_deletion',
    targetId: userId,
    before,
    after: { pending_deletion_at: null, pending_deletion_sentiment: null },
    actorId: admin.id,
  });
  revalidatePath('/users');
  revalidatePath(`/users/${userId}`);
  return { ok: true };
}

/// Generate a fresh 6-digit email OTP for a user without sending the
/// email — for support cases where the user can't receive their own
/// code (lost mailbox, deliverability issues). Uses Supabase Auth's
/// admin.generateLink({ type: 'magiclink' }), which returns the same
/// `email_otp` value that signInWithOtp would have emailed. The iOS
/// client verifies via verifyOTP(type: .email), and email-based OTPs
/// are interchangeable across the magiclink/email type pairs in
/// gotrue, so the returned code drops straight into the existing
/// "请输入验证码" screen.
///
/// We deliberately don't write the code itself into admin_audit —
/// audit rows are visible to other admins and to anyone with read
/// access to the table; the code is a one-shot session credential and
/// shouldn't sit in a log. The audit entry just records that an admin
/// minted a code for this target.
export async function generateLoginCode(
  userId: string,
): Promise<{ code?: string; email?: string; error?: string }> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();

  const { data: row } = await supa
    .from('users')
    .select('email')
    .eq('id', userId)
    .maybeSingle();
  if (!row?.email) return { error: '该用户没有邮箱,无法生成 OTP' };

  const { data, error } = await supa.auth.admin.generateLink({
    type: 'magiclink',
    email: row.email,
  });
  const otp = data?.properties?.email_otp;
  if (error || !otp) {
    return { error: error?.message ?? '生成失败（OTP 未返回）' };
  }

  await audit({
    action: 'user.generate_login_code',
    targetId: userId,
    before: null,
    after: { email: row.email },
    actorId: admin.id,
  });

  return { code: otp, email: row.email };
}
