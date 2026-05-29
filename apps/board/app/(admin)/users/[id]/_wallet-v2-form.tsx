'use client';

import { useActionState, useState } from 'react';
import { useFormToast } from '@/components/use-form-error-toast';
import { fmtPncMicros } from '@/lib/format';
import type { WalletV2FormState } from '../actions';

// Billing v2 admin grant / claw-back form. PNC value (±, up to 2 decimals)
// + reason. Amounts over 100 PNC require ticking the confirm box, matching
// the §12 double-confirm rule. Lives next to the v1 GrantForm during the
// dual-write window so admin can act on either ledger.

export function WalletV2Form({
  action,
}: {
  action: (prev: WalletV2FormState, formData: FormData) => Promise<WalletV2FormState>;
}) {
  const [state, formAction, pending] = useActionState<WalletV2FormState, FormData>(action, {});
  const [pnc, setPnc] = useState('');
  const needsConfirm = Math.abs(Number.parseFloat(pnc) || 0) > 100;

  useFormToast(
    state,
    state.ok
      ? `已调整 ${state.ok.pnc} PNC · 新余额 ${fmtPncMicros(state.ok.new_balance_micros)}`
      : '已调整',
    state.ok ? `${state.ok.pnc}|${state.ok.new_balance_micros}` : undefined,
  );

  return (
    <form action={formAction} className="space-y-3">
      <div className="grid grid-cols-3 gap-3">
        <label className="text-sm space-y-1 col-span-1">
          <span className="text-muted-foreground">PNC (±)</span>
          <input
            name="pnc"
            type="number"
            step="0.01"
            placeholder="50"
            required
            value={pnc}
            onChange={(e) => setPnc(e.target.value)}
            className="w-full rounded-md border border-input bg-background px-2 py-1 tabular-nums"
          />
        </label>
        <label className="text-sm space-y-1 col-span-2">
          <span className="text-muted-foreground">理由 (写在 ledger metadata)</span>
          <input
            name="reason"
            type="text"
            placeholder="bug 补偿 / 客服退款 / ..."
            className="w-full rounded-md border border-input bg-background px-2 py-1"
          />
        </label>
      </div>
      {needsConfirm && (
        <label className="flex items-center gap-2 text-xs text-amber-700">
          <input name="confirm" type="checkbox" value="yes" className="size-3.5" />
          金额超过 100 PNC，确认执行（二次确认）
        </label>
      )}
      <div className="flex items-center justify-between gap-3">
        <div className="text-xs">
          {state.error && <span className="text-destructive">{state.error}</span>}
          {state.ok && (
            <span className="text-emerald-700">
              ✓ 调整 {state.ok.pnc} PNC · 新余额 {fmtPncMicros(state.ok.new_balance_micros)}
            </span>
          )}
        </div>
        <button
          type="submit"
          disabled={pending}
          className="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground disabled:opacity-50"
        >
          {pending ? '执行中…' : '调整 v2 钱包'}
        </button>
      </div>
    </form>
  );
}
