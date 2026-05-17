'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import type { SaveLetterState } from './_shared';

const SLUG = 'readme';

export async function savePresetLetter(
  _prev: SaveLetterState,
  formData: FormData,
): Promise<SaveLetterState> {
  const admin = await requireAdmin();
  const title = String(formData.get('title') ?? '').trim();
  const summary = String(formData.get('summary') ?? '').trim();
  const body_md = String(formData.get('body_md') ?? '');

  if (!title) return { error: '标题不能为空' };
  if (!summary) return { error: '副标题不能为空' };
  if (!body_md.trim()) return { error: '正文不能为空' };

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('preset_letters')
    .select('title, summary, body_md, version')
    .eq('slug', SLUG)
    .maybeSingle();

  const nextVersion = (before?.version ?? 0) + 1;
  const { error } = await supa.from('preset_letters').upsert(
    {
      slug: SLUG,
      title,
      summary,
      body_md,
      version: nextVersion,
      updated_at: new Date().toISOString(),
      updated_by: admin.id,
    },
    { onConflict: 'slug' },
  );
  if (error) return { error: error.message };

  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: admin.id,
    action: 'preset_letters.upsert',
    target_kind: 'preset_letters',
    target_id: SLUG,
    before: before as never,
    after: { title, summary, body_md, version: nextVersion } as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });

  revalidatePath('/letters');
  return { ok: true };
}
