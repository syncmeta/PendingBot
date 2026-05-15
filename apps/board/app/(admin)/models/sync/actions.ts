'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { fetchOpenRouterSpecs } from '@/lib/openrouter-spec';

// Pull a single canonical model's metadata from OpenRouter and
// overwrite the columns we treat as OR-authoritative:
//   - context_window      (from top_provider.context_length)
//   - max_output_tokens   (from top_provider.max_completion_tokens)
//   - capabilities        (derived from architecture + supported_parameters)
//   - display_name        (only if currently empty — operator-set name wins)
//
// Pricing is not touched here — that's the /aliases/upstream flow's job.
// Sync is per-row so admins can selectively apply when OR changes
// surprise them.

export type SyncResult = { ok?: true; error?: string; message?: string };

export async function syncOneModel(id: string): Promise<SyncResult> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();

  const { data: before, error: loadErr } = await supa
    .from('llm_models')
    .select(
      'id, slug, display_name, context_window, max_output_tokens, capabilities, openrouter_canonical_slug',
    )
    .eq('id', id)
    .maybeSingle();
  if (loadErr) return { error: loadErr.message };
  if (!before) return { error: 'model 不存在' };
  if (!before.openrouter_canonical_slug) {
    return { error: '该 model 没有设置 openrouter_canonical_slug' };
  }

  let specs;
  try {
    specs = await fetchOpenRouterSpecs();
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) };
  }
  const spec = specs.get(before.openrouter_canonical_slug);
  if (!spec) {
    return {
      error: `OpenRouter catalog 里找不到 ${before.openrouter_canonical_slug}`,
    };
  }

  const after = {
    context_window: spec.contextLength,
    max_output_tokens: spec.maxCompletionTokens,
    capabilities: spec.capabilities,
    // Only fill display_name when the admin hasn't set one — never
    // clobber a curated label with OR's verbose "Vendor: Model" form.
    display_name: before.display_name || spec.name,
    updated_at: new Date().toISOString(),
  };

  const { error: updErr } = await supa
    .from('llm_models')
    .update(after as never)
    .eq('id', id);
  if (updErr) return { error: updErr.message };

  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: admin.id,
    action: 'model.sync_from_openrouter',
    target_kind: 'llm_model',
    target_id: id,
    before: before as never,
    after: after as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });

  revalidatePath('/models');
  revalidatePath('/models/sync');
  return { ok: true, message: `已从 OpenRouter 同步 ${before.slug}` };
}
