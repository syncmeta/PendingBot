'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';

// Server actions for the Tools admin page. Edge worker reads
// pendingbot.tools on a 60s isolate cache and intersects its
// advertised tool list with enabled=true rows (see
// apps/edge/src/lib/tools-registry.ts). A toggle here strips the
// tool from the model surface within ~1 min, no deploy.

export type ActionResult = { ok?: true; error?: string; message?: string };

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
