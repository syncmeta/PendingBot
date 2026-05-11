'use client';

import { useActionState } from 'react';
import { useFormToast } from '@/components/use-form-error-toast';
import type { PriceFormState } from './actions';

export type PriceRow = {
  provider: string;
  kind: 'search' | 'scrape' | string;
  unit_cost_usd: number;
  notes: string | null;
  updated_at: string;
};

export type UsageCell = {
  count: number;
  errors: number;
  usd: number;
} | null;

// USD→PND display ratio; mirrors USD_TO_PND in apps/edge/src/lib/billing.ts.
// The markup arrives as a prop from the page (sourced from billing_config),
// so this component never holds a duplicate of that knob.
const USD_TO_PND = 2700;

export function PriceRowForm({
  row,
  usage,
  markup,
  action,
}: {
  row: PriceRow;
  usage: UsageCell;
  markup: number;
  action: (prev: PriceFormState, fd: FormData) => Promise<PriceFormState>;
}) {
  const [state, formAction, pending] = useActionState<PriceFormState, FormData>(
    action,
    {},
  );
  useFormToast(state, `已保存 ${row.provider}/${row.kind} 价格`);
  const billed = Math.ceil(row.unit_cost_usd * USD_TO_PND * markup);

  return (
    <tr className="border-b align-top last:border-0">
      <td className="px-4 py-3 font-mono text-xs">
        {row.provider}
        <div className="text-[10px] text-muted-foreground">{row.kind}</div>
      </td>
      <td className="px-4 py-3">
        <form action={formAction} className="space-y-2">
          <div className="flex items-center gap-3">
            <input
              name="unit_cost_usd"
              type="number"
              required
              min="0"
              step="0.000001"
              defaultValue={row.unit_cost_usd}
              className="w-32 rounded-md border border-input bg-background px-2 py-1 text-right font-mono text-sm tabular-nums"
            />
            <span className="text-xs text-muted-foreground">
              USD/次 → 用户每次扣 ≈{' '}
              <span className="tabular-nums">{billed.toLocaleString()} ∂</span>
              <span className="text-muted-foreground/70">
                {' '}
                (markup {markup}×)
              </span>
            </span>
          </div>
          <textarea
            name="notes"
            rows={2}
            defaultValue={row.notes ?? ''}
            placeholder="备注（哪家定价页、套餐档位之类）"
            className="block w-full rounded-md border border-input bg-background px-2 py-1 text-xs"
          />
          <div className="flex items-center gap-3">
            <button
              type="submit"
              disabled={pending}
              className="rounded-md bg-primary px-3 py-1 text-xs font-medium text-primary-foreground disabled:opacity-50"
            >
              {pending ? '保存中…' : '保存'}
            </button>
            {state.error && (
              <span className="text-xs text-destructive">{state.error}</span>
            )}
            {state.ok && !pending && (
              <span className="text-xs text-emerald-700">已保存</span>
            )}
            <span className="ml-auto text-[10px] text-muted-foreground">
              上次更新 {new Date(row.updated_at).toLocaleString()}
            </span>
          </div>
        </form>
      </td>
      <td className="px-4 py-3 text-xs text-muted-foreground tabular-nums">
        {usage ? (
          <div className="space-y-1">
            <div>{usage.count.toLocaleString()} 次</div>
            {usage.errors > 0 && (
              <div className="text-amber-700">{usage.errors} 次错误</div>
            )}
            <div>≈ ${usage.usd.toFixed(4)}</div>
          </div>
        ) : (
          '—'
        )}
      </td>
    </tr>
  );
}
