import { notFound } from 'next/navigation';
import Link from 'next/link';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { supabaseAdmin } from '@/lib/supabase/admin';
import {
  PROMPT_NAMES,
  PROMPT_DESCRIPTIONS,
  type PromptName,
} from '@pendingbot/edge/llm/prompt-names';
import { SUPPORTED_LOCALES, type PromptLocale } from '../../_shared';
import { PromptEditor } from './editor';

// Best-effort read of the bundled .md from the sibling apps/edge tree. Works
// in `next dev` and in `next start` runs that have the monorepo source on
// disk. If the runtime environment doesn't (e.g. an isolated container
// build), we fall back to an empty placeholder — the user just won't see
// the "(bundled default)" preview.
async function readBundled(name: string, locale: string): Promise<string | null> {
  try {
    const p = path.resolve(
      process.cwd(),
      '..',
      'edge',
      'prompts',
      locale,
      `${name}.md`,
    );
    return await fs.readFile(p, 'utf-8');
  } catch {
    return null;
  }
}

export default async function PromptEditPage({
  params,
}: {
  params: Promise<{ name: string; locale: string }>;
}) {
  const { name, locale } = await params;

  if (!(PROMPT_NAMES as readonly string[]).includes(name)) notFound();
  if (!(SUPPORTED_LOCALES as readonly string[]).includes(locale)) notFound();

  const supa = supabaseAdmin();
  const { data: override } = await supa
    .from('i18n_prompts')
    .select('body_md, version, updated_at, updated_by')
    .eq('name', name)
    .eq('locale', locale)
    .maybeSingle();

  const bundled = await readBundled(name, locale);
  const initialBody = override?.body_md ?? bundled ?? '';

  return (
    <main className="container py-10 space-y-4">
      <nav className="text-sm text-muted-foreground">
        <Link href="/prompts" className="underline">
          ← AI Prompts
        </Link>
      </nav>

      <header className="space-y-1">
        <h1 className="text-xl font-bold tracking-tight">
          <span className="font-mono">{name}</span>{' '}
          <span className="text-muted-foreground">/ {locale}</span>
        </h1>
        <p className="text-sm text-muted-foreground">
          {PROMPT_DESCRIPTIONS[name as PromptName]}
        </p>
        {override ? (
          <p className="text-xs text-muted-foreground">
            DB 覆盖 v{override.version}，更新于{' '}
            {new Date(override.updated_at).toLocaleString('zh-CN')}
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            当前未覆盖（edge 走 bundled <code>.md</code>）
          </p>
        )}
      </header>

      <PromptEditor
        name={name}
        locale={locale as PromptLocale}
        initialBody={initialBody}
        overrideVersion={override?.version ?? null}
        bundledBody={
          bundled ??
          '(bundled 内容在当前部署环境不可读 — 在本地 dev 起 board 可以看到)'
        }
      />
    </main>
  );
}
