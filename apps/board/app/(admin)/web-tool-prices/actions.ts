'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

// Edit wholesale unit costs for external search / scrape providers.
// The table is keyed by (provider, kind) so the page never adds or
// removes rows here — additions happen via a migration when a new
// provider gets wired into the edge worker. This action only updates
// unit_cost_usd + notes on an existing row.

export type PriceFormState = { error?: string; ok?: boolean };

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
    target_kind: 'web_tool_price',
    target_id: args.targetId,
    before: (args.before ?? null) as never,
    after: (args.after ?? null) as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function updateWebToolPrice(
  provider: string,
  kind: string,
  _prev: PriceFormState,
  formData: FormData,
): Promise<PriceFormState> {
  const admin = await requireAdmin();

  const costRaw = String(formData.get('unit_cost_usd') ?? '').trim();
  const cost = Number(costRaw);
  if (!Number.isFinite(cost) || cost < 0) {
    return { error: 'unit_cost_usd 必须是 ≥ 0 的数字' };
  }
  const notesRaw = String(formData.get('notes') ?? '').trim();
  const notes = notesRaw ? notesRaw : null;

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('web_tool_prices')
    .select('*')
    .eq('provider', provider)
    .eq('kind', kind)
    .maybeSingle();
  if (!before) return { error: '记录不存在，请刷新页面' };

  const { error } = await supa
    .from('web_tool_prices')
    .update({
      unit_cost_usd: cost,
      notes,
      updated_at: new Date().toISOString(),
    })
    .eq('provider', provider)
    .eq('kind', kind);
  if (error) return { error: error.message };

  await audit({
    action: 'web_tool_price.update',
    targetId: `${provider}:${kind}`,
    before,
    after: { unit_cost_usd: cost, notes },
    actorId: admin.id,
  });

  revalidatePath('/web-tool-prices');
  // Stay on the page — show "已保存" inline. Per-row inline edit is
  // the whole UX here, no list/detail switch to redirect to.
  return { ok: true };
}
