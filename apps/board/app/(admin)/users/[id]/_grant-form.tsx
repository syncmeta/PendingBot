'use client';

import { useActionState } from 'react';
import { useFormToast } from '@/components/use-form-error-toast';
import type { GrantFormState } from '../actions';

// Inline grant form that lives inside the user's detail page. Shows
// "新余额 = X" feedback after submit so admin can confirm without
// hunting for the number elsewhere on the page.

export function GrantForm({
  action,
}: {
  action: (prev: GrantFormState, formData: FormData) => Promise<GrantFormState>;
}) {
  const [state, formAction, pending] = useActionState<GrantFormState, FormData>(action, {});
  useFormToast(
    state,
    state.ok
      ? `已发放 ∂${state.ok.credits} · 新余额 ∂${state.ok.new_balance}`
      : '已发放',
    state.ok ? `${state.ok.credits}|${state.ok.new_balance}` : undefined,
  );
  return (
    <form action={formAction} className="space-y-3">
      <div className="grid grid-cols-3 gap-3">
        <label className="text-sm space-y-1 col-span-1">
          <span className="text-muted-foreground">PND ∂ (±)</span>
          <input
            name="credits"
            type="number"
            step="1"
            placeholder="2700"
            required
            className="w-full rounded-md border border-input bg-background px-2 py-1 tabular-nums"
          />
        </label>
        <label className="text-sm space-y-1 col-span-2">
          <span className="text-muted-foreground">理由 (写在 ledger 上)</span>
          <input
            name="reason"
            type="text"
            placeholder="bug 补偿 / beta thanks / ..."
            className="w-full rounded-md border border-input bg-background px-2 py-1"
          />
        </label>
      </div>
      <div className="flex items-center justify-between gap-3">
        <div className="text-xs">
          {state.error && (
            <span className="text-destructive">{state.error}</span>
          )}
          {state.ok && (
            <span className="text-emerald-700">
              ✓ 发放 ∂{state.ok.credits} · 新余额 ∂{state.ok.new_balance}
            </span>
          )}
        </div>
        <button
          type="submit"
          disabled={pending}
          className="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground disabled:opacity-50"
        >
          {pending ? '发放中…' : '发放'}
        </button>
      </div>
    </form>
  );
}
