'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import {
  PROMPT_NAMES,
  type PromptName,
} from '@pendingbot/edge/llm/prompt-names';
import {
  SUPPORTED_LOCALES,
  type PromptLocale,
  type SavePromptState,
} from './_shared';

function assertPromptName(s: string): asserts s is PromptName {
  if (!(PROMPT_NAMES as readonly string[]).includes(s)) {
    throw new Error(`unknown prompt name: ${s}`);
  }
}
function assertLocale(s: string): asserts s is PromptLocale {
  if (!(SUPPORTED_LOCALES as readonly string[]).includes(s)) {
    throw new Error(`unsupported locale: ${s}`);
  }
}

export async function savePrompt(
  _prev: SavePromptState,
  formData: FormData,
): Promise<SavePromptState> {
  const admin = await requireAdmin();
  const name = String(formData.get('name') ?? '');
  const locale = String(formData.get('locale') ?? '');
  const body_md = String(formData.get('body_md') ?? '');

  try {
    assertPromptName(name);
    assertLocale(locale);
  } catch (e) {
    return { error: (e as Error).message };
  }
  if (!body_md.trim()) {
    return { error: 'body 不能为空（若想用 bundled 默认，请用"重置")' };
  }

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('i18n_prompts')
    .select('body_md, version')
    .eq('name', name)
    .eq('locale', locale)
    .maybeSingle();

  const nextVersion = (before?.version ?? 0) + 1;
  const { error } = await supa.from('i18n_prompts').upsert(
    {
      name,
      locale,
      body_md,
      version: nextVersion,
      updated_at: new Date().toISOString(),
      updated_by: admin.id,
    },
    { onConflict: 'name,locale' },
  );
  if (error) return { error: error.message };

  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: admin.id,
    action: 'i18n_prompts.upsert',
    target_kind: 'i18n_prompts',
    target_id: `${name}/${locale}`,
    before: (before ? { body_md: before.body_md, version: before.version } : null) as never,
    after: { body_md, version: nextVersion } as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });

  revalidatePath('/prompts');
  revalidatePath(`/prompts/${name}/${locale}`);
  return { ok: true };
}

export async function resetPrompt(name: string, locale: string): Promise<void> {
  const admin = await requireAdmin();
  assertPromptName(name);
  assertLocale(locale);

  const supa = supabaseAdmin();
  const { data: before } = await supa
    .from('i18n_prompts')
    .select('body_md, version')
    .eq('name', name)
    .eq('locale', locale)
    .maybeSingle();
  if (!before) {
    revalidatePath('/prompts');
    revalidatePath(`/prompts/${name}/${locale}`);
    return;
  }

  await supa
    .from('i18n_prompts')
    .delete()
    .eq('name', name)
    .eq('locale', locale);

  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: admin.id,
    action: 'i18n_prompts.reset',
    target_kind: 'i18n_prompts',
    target_id: `${name}/${locale}`,
    before: { body_md: before.body_md, version: before.version } as never,
    after: null,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });

  revalidatePath('/prompts');
  revalidatePath(`/prompts/${name}/${locale}`);
}
