import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import {
  PROMPT_NAMES,
  PROMPT_DESCRIPTIONS,
} from '@pendingbot/edge/llm/prompt-names';
import { SUPPORTED_LOCALES } from './actions';

export default async function PromptsPage() {
  const supa = supabaseAdmin();
  const { data: rows } = await supa
    .from('i18n_prompts')
    .select('name, locale, version, updated_at');

  const overrides = new Map<string, { version: number; updated_at: string }>();
  for (const r of rows ?? []) {
    overrides.set(`${r.name}/${r.locale}`, {
      version: r.version,
      updated_at: r.updated_at,
    });
  }

  return (
    <main className="container py-10 space-y-6">
      <header>
        <h1 className="text-2xl font-bold tracking-tight">AI Prompts</h1>
        <p className="text-sm text-muted-foreground">
          每条 prompt 的 (名字 × 语言) 单元格。未覆盖时 edge 走仓库 bundled
          的 <code>.md</code>；编辑后写入 DB 覆盖。生效窗口 ≤ 30s（worker
          isolate cache TTL）。
        </p>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted/40 text-xs uppercase tracking-wide text-muted-foreground">
            <tr>
              <th className="px-4 py-2 text-left">Prompt</th>
              <th className="px-4 py-2 text-left">说明</th>
              {SUPPORTED_LOCALES.map((loc) => (
                <th key={loc} className="px-4 py-2 text-left">
                  {loc}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {PROMPT_NAMES.map((name) => (
              <tr key={name} className="border-t">
                <td className="px-4 py-2 font-mono">{name}</td>
                <td className="px-4 py-2 text-muted-foreground">
                  {PROMPT_DESCRIPTIONS[name]}
                </td>
                {SUPPORTED_LOCALES.map((loc) => {
                  const ov = overrides.get(`${name}/${loc}`);
                  return (
                    <td key={loc} className="px-4 py-2">
                      <Link
                        href={`/prompts/${name}/${loc}`}
                        className="inline-flex items-center gap-2 underline-offset-2 hover:underline"
                      >
                        {ov ? (
                          <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-xs text-emerald-800">
                            v{ov.version}
                          </span>
                        ) : (
                          <span className="rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
                            bundled
                          </span>
                        )}
                        <span className="text-xs">编辑</span>
                      </Link>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </main>
  );
}
