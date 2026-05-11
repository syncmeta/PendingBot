'use client';

import { useActionState } from 'react';
import { useFormToast } from '@/components/use-form-error-toast';
import type { MarkupFormState } from './actions';

// Inline editor for billing_config.markup. Lives on the /billing
// dashboard because the markup multiplier is part of the same
// "billing knobs" surface as min_balance_threshold (next door to it
// conceptually — same table, same propagation TTL).

export function MarkupEditor({
  current,
  action,
}: {
  current: number;
  action: (prev: MarkupFormState, fd: FormData) => Promise<MarkupFormState>;
}) {
  const [state, formAction, pending] = useActionState<MarkupFormState, FormData>(
    action,
    {},
  );
  useFormToast(state, '已保存 markup');
  return (
    <form
      action={formAction}
      className="flex flex-wrap items-center gap-3 rounded-lg border bg-card px-4 py-3"
    >
      <span className="text-xs uppercase tracking-wide text-muted-foreground">
        Markup
      </span>
      <input
        name="markup"
        type="number"
        required
        min="0.1"
        step="0.05"
        defaultValue={current}
        className="w-24 rounded-md border border-input bg-background px-2 py-1 text-right font-mono text-sm tabular-nums"
      />
      <span className="text-xs text-muted-foreground">×</span>
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
      <span className="ml-auto text-[11px] text-muted-foreground">
        生效窗口 ≤ 60s（worker 缓存 TTL）
      </span>
    </form>
  );
}
