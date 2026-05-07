'use client';

import { useState } from 'react';

// Just-issued code banner. Client component so we can do clipboard
// copy without a round-trip. Codes only ever pass through here right
// after issuance (via /billing/codes?just=… or ?just_codes=…). Once
// the user navigates away there's no other surface that re-displays
// the full code list — the codes table only shows the first/middle
// chars by virtue of being a normal cell, but here we render full
// hex strings on purpose so the admin can copy them all in one go.

export function JustIssued({
  codes,
  label,
}: {
  codes: string[];
  label: string | null;
}) {
  const [copied, setCopied] = useState<'all' | string | null>(null);

  const copy = async (text: string, key: 'all' | string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(key);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      // clipboard might be denied — fall through silently.
    }
  };

  return (
    <section className="rounded-lg border border-emerald-300 bg-emerald-50/60 p-4 space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-sm font-medium text-emerald-900">
            刚发了 {codes.length} 个码{label ? ` · 批次 ${label}` : ''}
          </div>
          <div className="text-xs text-emerald-800/80">
            离开本页就看不到完整列表了 — 现在复制保存。
          </div>
        </div>
        <button
          type="button"
          onClick={() => copy(codes.join('\n'), 'all')}
          className="rounded-md bg-emerald-600 px-3 py-1.5 text-sm text-white hover:bg-emerald-700"
        >
          {copied === 'all' ? '✓ 已复制全部' : '复制全部'}
        </button>
      </div>
      <div className="grid gap-1 max-h-72 overflow-y-auto rounded-md border border-emerald-200 bg-white/70 p-2 font-mono text-xs">
        {codes.map((c) => (
          <button
            type="button"
            key={c}
            onClick={() => copy(c, c)}
            className="text-left rounded px-2 py-0.5 hover:bg-emerald-100"
            title="点击复制"
          >
            <span className="tabular-nums">{c}</span>
            {copied === c && (
              <span className="ml-2 text-emerald-700">✓</span>
            )}
          </button>
        ))}
      </div>
    </section>
  );
}
