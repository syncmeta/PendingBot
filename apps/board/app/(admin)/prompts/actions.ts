'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import {
  PROMPT_NAMES,
  type PromptName,
} from '@pendingbot/edge/llm/prompt-names';

// pendingbot.i18n_prompts is freshly created (migration
// 20260511064939_i18n_prompts.sql) and not yet in apps/edge/src/db/schema.ts.
// Use a thin typed gateway to keep the casts in one place — once schema is
// regenerated this collapses to direct supa.from('i18n_prompts').
type PromptRow = {
  name: string;
  locale: string;
  body_md: string;
  version: number;
  updated_at: string;
  updated_by: string | null;
};
type AnySupa = ReturnType<typeof supabaseAdmin>;
function promptsTable(supa: AnySupa) {
  return (supa as unknown as {
    from: (t: string) => {
      select: (cols: string) => Promise<{ data: PromptRow[] | null; error: { message: string } | null }> & {
        eq: (col: string, val: string) => {
          eq: (col: string, val: string) => {
            maybeSingle: () => Promise<{ data: PromptRow | null; error: { message: string } | null }>;
          };
        };
      };
      upsert: (
        row: Partial<PromptRow>,
        opts?: { onConflict?: string },
      ) => Promise<{ error: { message: string } | null }>;
      delete: () => {
        eq: (col: string, val: string) => {
          eq: (col: string, val: string) => Promise<{ error: { message: string } | null }>;
        };
      };
    };
  }).from('i18n_prompts');
}

export const SUPPORTED_LOCALES = ['zh', 'en'] as const;
export type PromptLocale = (typeof SUPPORTED_LOCALES)[number];

export type SavePromptState = { error?: string; ok?: boolean };

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
  const { data: before } = await promptsTable(supa)
    .select('name, locale, body_md, version, updated_at, updated_by')
    .eq('name', name)
    .eq('locale', locale)
    .maybeSingle();

  const nextVersion = (before?.version ?? 0) + 1;
  const { error } = await promptsTable(supa).upsert(
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
  const { data: before } = await promptsTable(supa)
    .select('name, locale, body_md, version, updated_at, updated_by')
    .eq('name', name)
    .eq('locale', locale)
    .maybeSingle();
  if (!before) {
    revalidatePath('/prompts');
    revalidatePath(`/prompts/${name}/${locale}`);
    return;
  }

  await promptsTable(supa).delete().eq('name', name).eq('locale', locale);

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
