'use server';

import { execFile } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
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
  type CommitPromptResult,
  type PromptLocale,
  type SavePromptState,
} from './_shared';

const execFileAsync = promisify(execFile);

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

// Resolve the repo-relative and on-disk path of a bundled prompt .md, the same
// way the editor reads the bundled default (sibling apps/edge tree). Board sits
// at apps/board, so the edge tree is one level up.
function bundledFile(name: string, locale: string): { rel: string; abs: string } {
  return {
    rel: `apps/edge/prompts/${locale}/${name}.md`,
    abs: path.resolve(process.cwd(), '..', 'edge', 'prompts', locale, `${name}.md`),
  };
}

// Mirror a saved prompt into the repo's bundled .md so git stays in sync with
// the DB override and the next edge deploy bakes in the same text. Only has an
// effect when Board runs locally with the monorepo source on disk.
async function writeBundled(
  name: string,
  locale: string,
  body_md: string,
): Promise<NonNullable<SavePromptState['bundled']>> {
  const { rel, abs } = bundledFile(name, locale);
  try {
    await fs.mkdir(path.dirname(abs), { recursive: true });
    await fs.writeFile(abs, body_md, 'utf-8');
    return { ok: true, path: rel };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

// Commit just the bundled .md for this prompt so a save doesn't leave the
// working tree dirty. Scoped to the single file by pathspec, so it never sweeps
// up other dirty files. Only works locally with the monorepo + git on disk.
export async function commitPrompt(
  name: string,
  locale: string,
): Promise<CommitPromptResult> {
  await requireAdmin();
  assertPromptName(name);
  assertLocale(locale);

  const { rel, abs } = bundledFile(name, locale);
  const cwd = path.dirname(abs);
  try {
    const { stdout: status } = await execFileAsync(
      'git',
      ['status', '--porcelain', '--', abs],
      { cwd },
    );
    if (!status.trim()) return { ok: true, committed: false };

    await execFileAsync('git', ['add', '--', abs], { cwd });
    await execFileAsync(
      'git',
      ['commit', '-m', `edge(prompts): update ${name}/${locale} via board`, '--', abs],
      { cwd },
    );
    const { stdout: sha } = await execFileAsync(
      'git',
      ['rev-parse', '--short', 'HEAD'],
      { cwd },
    );
    return { ok: true, committed: true, sha: sha.trim(), path: rel };
  } catch (e) {
    const err = e as { stderr?: string; message?: string };
    return { ok: false, error: (err.stderr || err.message || 'git failed').trim() };
  }
}

export async function savePrompt(
  _prev: SavePromptState,
  formData: FormData,
): Promise<SavePromptState> {
  const admin = await requireAdmin();
  const name = String(formData.get('name') ?? '');
  const locale = String(formData.get('locale') ?? '');
  // Textareas submit with CRLF per the HTML spec; normalize to LF so both the
  // DB override and the bundled .md stay in Unix line endings.
  const body_md = String(formData.get('body_md') ?? '').replace(/\r\n?/g, '\n');

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

  const bundled = await writeBundled(name, locale, body_md);

  revalidatePath('/prompts');
  revalidatePath(`/prompts/${name}/${locale}`);
  return { ok: true, bundled };
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
