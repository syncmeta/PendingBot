'use client';

import { useActionState } from 'react';
import { useFormErrorToast } from '@/components/use-form-error-toast';
import type { ProviderFormState } from './actions';

export type ProviderFormValues = {
  slug?: string;
  display_name?: string;
  base_url?: string;
  enabled?: boolean;
  priority?: number;
  notes?: string | null;
};

export function ProviderForm({
  action,
  initial,
  submitLabel,
  lockedSlug,
}: {
  action: (prev: ProviderFormState, formData: FormData) => Promise<ProviderFormState>;
  initial?: ProviderFormValues;
  submitLabel: string;
  lockedSlug?: boolean;
}) {
  const [state, formAction, pending] = useActionState<ProviderFormState, FormData>(
    action,
    {},
  );
  useFormErrorToast(state.error);

  return (
    <form action={formAction} className="space-y-4">
      <Field label="slug" hint="路由器代码里用的稳定标识，如 openrouter / openai">
        <input
          name="slug"
          required
          defaultValue={initial?.slug ?? ''}
          readOnly={lockedSlug}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm read-only:bg-muted"
        />
      </Field>
      <Field label="display_name" hint="给人看的名字">
        <input
          name="display_name"
          required
          defaultValue={initial?.display_name ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
      </Field>
      <Field
        label="base_url"
        hint="AI Gateway 端点根路径，如 https://gateway.ai.cloudflare.com/v1/<account>/pendingbot/openrouter"
      >
        <input
          name="base_url"
          required
          type="url"
          defaultValue={initial?.base_url ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
        />
      </Field>
      <Field label="priority" hint="数字越小越优先（同 weight 时 tiebreaker）">
        <input
          name="priority"
          type="number"
          defaultValue={initial?.priority ?? 100}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
        />
      </Field>
      <Field label="备注（可选）">
        <textarea
          name="notes"
          rows={3}
          defaultValue={initial?.notes ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
      </Field>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          name="enabled"
          defaultChecked={initial?.enabled ?? true}
          className="h-4 w-4"
        />
        启用
      </label>

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
        {pending ? '保存中…' : submitLabel}
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
