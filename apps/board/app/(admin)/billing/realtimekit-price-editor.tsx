'use client';

import { useActionState } from 'react';
import { useFormToast } from '@/components/use-form-error-toast';
import type { RealtimeKitPriceFormState } from './actions';

export function RealtimeKitPriceEditor({
  current,
  action,
}: {
  current: number;
  action: (prev: RealtimeKitPriceFormState, fd: FormData) => Promise<RealtimeKitPriceFormState>;
}) {
  const [state, formAction, pending] = useActionState<RealtimeKitPriceFormState, FormData>(
    action,
    {},
  );
  useFormToast(state, '已保存 RealtimeKit 价格');
  return (
    <form
      action={formAction}
      className="flex flex-wrap items-center gap-3 rounded-lg border bg-card px-4 py-3"
    >
      <span className="text-xs uppercase tracking-wide text-muted-foreground">
        RealtimeKit audio
      </span>
      <input
        name="price"
        type="number"
        required
        min="0"
        step="0.0001"
        defaultValue={current}
        className="w-28 rounded-md border border-input bg-background px-2 py-1 text-right font-mono text-sm tabular-nums"
      />
      <span className="text-xs text-muted-foreground">USD / participant-min</span>
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
        设为 0 可暂停媒体成本转嫁
      </span>
    </form>
  );
}
