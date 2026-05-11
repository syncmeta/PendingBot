import Link from 'next/link';
import { DiffTable } from './_diff-table';

// Manual "pull upstream prices, review diff, apply selected" workflow.
// No fetch happens on page load — admin clicks the button. Pull
// returns a snapshot (no DB writes); apply writes exactly that
// snapshot to llm_model_aliases for the rows the admin checked.
//
// Providers reached:
//   - openrouter   → /v1/models (anonymous)
//   - worldrouter  → mirrors openrouter × 0.7 (per provider config)
//   - everything else → "no upstream fetch wired up" note per row

export default function AliasesUpstreamPage() {
  return (
    <main className="container py-10 space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">
            Aliases · 上游价格对账
          </h1>
          <p className="text-sm text-muted-foreground">
            手动从上游拉一份价目，逐行核对，勾选要应用的再写库。WorldRouter
            走 OpenRouter × 0.7 镜像（在 provider.config.pricing_source
            里配的）。
          </p>
        </div>
        <Link
          href="/aliases"
          className="rounded-md border border-input px-3 py-1.5 text-sm hover:bg-accent"
        >
          返回 alias 列表
        </Link>
      </header>

      <DiffTable />

      <p className="text-xs text-muted-foreground">
        单位都是 USD / 1M tokens。input / output 是 NOT NULL 列——
        如果上游没暴露这两个的某一个，应用时会保留原值而不是写 null。
      </p>
    </main>
  );
}
