'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

// Server actions for the /billing dashboard's inline knobs. Currently
// just the markup multiplier; min_balance_threshold lives in the same
// billing_config table and could be added here later.

export type MarkupFormState = { error?: string; ok?: boolean };

export async function setMarkup(
  _prev: MarkupFormState,
  formData: FormData,
): Promise<MarkupFormState> {
  const admin = await requireAdmin();
  const raw = String(formData.get('markup') ?? '').trim();
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    return { error: 'markup 必须是 > 0 的数字' };
  }
  // Sanity ceiling — anything past 10× is almost certainly a typo
  // and would lock users out of features. Easy to lift later.
  if (value > 10) {
    return { error: 'markup > 10 看起来像误输入，请确认' };
  }

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('billing_config')
    .select('value')
    .eq('key', 'markup')
    .maybeSingle();
  const previous = before?.value ?? null;

  const { error } = await supa
    .from('billing_config')
    .upsert(
      { key: 'markup', value: value as unknown as never, updated_at: new Date().toISOString() },
      { onConflict: 'key' },
    );
  if (error) return { error: error.message };

  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: admin.id,
    action: 'billing_config.update',
    target_kind: 'billing_config',
    target_id: 'markup',
    before: { value: previous } as never,
    after: { value } as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });

  revalidatePath('/billing');
  revalidatePath('/web-tool-prices');
  return { ok: true };
}
