'use client';

import { useActionState } from 'react';
import type { QuotaFormState } from '../actions';

export function QuotaForm({
  action,
  initial,
}: {
  action: (prev: QuotaFormState, formData: FormData) => Promise<QuotaFormState>;
  initial: { daily_limit_usd: number; monthly_limit_usd: number };
}) {
  const [state, formAction, pending] = useActionState<QuotaFormState, FormData>(action, {});
  return (
    <form action={formAction} className="space-y-4">
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="daily_limit_usd" hint="日上限（USD）">
          <input
            name="daily_limit_usd"
            type="number"
            step="0.01"
            min={0}
            required
            defaultValue={initial.daily_limit_usd}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
          />
        </Field>
        <Field label="monthly_limit_usd" hint="月上限（USD）">
          <input
            name="monthly_limit_usd"
            type="number"
            step="0.01"
            min={0}
            required
            defaultValue={initial.monthly_limit_usd}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
          />
        </Field>
      </div>

      {state.error && (
        <p className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          {state.error}
        </p>
      )}

      <button
        type="submit"
        disabled={pending}
        className="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
      >
        {pending ? '保存中…' : '保存'}
      </button>
    </form>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <label className="block text-sm font-medium">{label}</label>
      {hint && <p className="mb-1 text-xs text-muted-foreground">{hint}</p>}
      {children}
    </div>
  );
}
