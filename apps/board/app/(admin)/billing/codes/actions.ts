'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

// Reuse the admin_audit pattern from users/actions.ts so billing-side
// admin moves are visible in the same /admin-audit feed.
async function audit(args: {
  action: string;
  targetId: string | null;
  before: unknown;
  after: unknown;
  actorId: string;
}) {
  const supa = supabaseAdmin();
  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: args.actorId,
    action: args.action,
    target_kind: 'redemption_code',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function issueCodes(formData: FormData) {
  const admin = await requireAdmin();
  const count = Number.parseInt(String(formData.get('count') ?? ''), 10);
  const credits = Number.parseInt(String(formData.get('credits') ?? ''), 10);
  const labelRaw = String(formData.get('label') ?? '').trim();
  const label = labelRaw || null;

  if (!Number.isFinite(count) || count <= 0 || count > 1000) {
    redirect('/billing/codes?err=count');
  }
  if (!Number.isFinite(credits) || credits <= 0) {
    redirect('/billing/codes?err=credits');
  }

  const supa = supabaseAdmin();
  const { data, error } = await supa.rpc('billing_issue_codes', {
    p_count: count,
    p_credits: credits,
    p_label: label ?? undefined,
  });
  if (error) {
    redirect(`/billing/codes?err=${encodeURIComponent(error.message)}`);
  }

  await audit({
    action: 'billing.issue_codes',
    targetId: null,
    before: null,
    after: { count, credits, label, codes_returned: (data ?? []).length },
    actorId: admin.id,
  });

  // Pass batch_label (or a synthetic key when label was empty) so the
  // page can show "just issued these" prominently. Fall back to passing
  // explicit code strings via the URL when no label was provided —
  // 1000 codes × 16 chars + commas fits well under URL length limits
  // for chrome (8k+).
  if (label) {
    revalidatePath('/billing/codes');
    redirect(`/billing/codes?just=${encodeURIComponent(label)}`);
  }
  const codes = (data as string[] | null) ?? [];
  revalidatePath('/billing/codes');
  redirect(
    `/billing/codes?just_codes=${encodeURIComponent(codes.join(','))}`,
  );
}

export type ActionResult = { ok?: true; error?: string; message?: string };

export async function disableCode(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('redemption_codes')
    .select('code, status')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: '兑换码不存在' };
  if (before.status === 'used') return { error: '该码已被使用,无法停用' };

  const { error } = await supa
    .from('redemption_codes')
    .update({ status: 'disabled' })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'billing.disable_code',
    targetId: id,
    before: { status: before.status },
    after: { status: 'disabled' },
    actorId: admin.id,
  });
  revalidatePath('/billing/codes');
  return { ok: true, message: `已停用 ${before.code}` };
}

export async function enableCode(id: string): Promise<ActionResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('redemption_codes')
    .select('code, status')
    .eq('id', id)
    .maybeSingle();
  if (!before) return { error: '兑换码不存在' };
  if (before.status !== 'disabled') return { error: '该码当前不是 disabled 状态' };

  const { error } = await supa
    .from('redemption_codes')
    .update({ status: 'enabled' })
    .eq('id', id);
  if (error) return { error: error.message };

  await audit({
    action: 'billing.enable_code',
    targetId: id,
    before: { status: 'disabled' },
    after: { status: 'enabled' },
    actorId: admin.id,
  });
  revalidatePath('/billing/codes');
  return { ok: true, message: `已启用 ${before.code}` };
}
