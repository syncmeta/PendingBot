'use client';

import { useActionState } from 'react';
import { useFormErrorToast } from '@/components/use-form-error-toast';
import type { AliasFormState } from './actions';

export type AliasFormValues = {
  model_id?: string;
  provider_id?: string;
  provider_model_id?: string;
  enabled?: boolean;
  weight?: number;
  input_price?: number | string | null;
  cached_input_price?: number | string | null;
  output_price?: number | string | null;
  cache_write_price?: number | string | null;
  notes?: string | null;
};

export type ProviderOption = { id: string; slug: string; display_name: string };
export type ModelOption = { id: string; slug: string; display_name: string };

export function AliasForm({
  action,
  initial,
  models,
  providers,
  submitLabel,
  modelLocked,
  providerLocked,
}: {
  action: (prev: AliasFormState, formData: FormData) => Promise<AliasFormState>;
  initial?: AliasFormValues;
  models: ModelOption[];
  providers: ProviderOption[];
  submitLabel: string;
  modelLocked?: boolean;
  providerLocked?: boolean;
}) {
  const [state, formAction, pending] = useActionState<AliasFormState, FormData>(action, {});
  useFormErrorToast(state.error);

  return (
    <form action={formAction} className="space-y-4">
      <Field
        label="model"
        hint="canonical 模型 — 在 /models 里注册"
      >
        <select
          name="model_id"
          required
          defaultValue={initial?.model_id ?? ''}
          disabled={modelLocked}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm disabled:opacity-60"
        >
          <option value="" disabled>
            选一个 model…
          </option>
          {models.map((m) => (
            <option key={m.id} value={m.id}>
              {m.slug} — {m.display_name}
            </option>
          ))}
        </select>
        {modelLocked && initial?.model_id && (
          <input type="hidden" name="model_id" value={initial.model_id} />
        )}
      </Field>

      <Field label="provider">
        <select
          name="provider_id"
          required
          defaultValue={initial?.provider_id ?? ''}
          disabled={providerLocked}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm disabled:opacity-60"
        >
          <option value="" disabled>
            选一个 provider…
          </option>
          {providers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.slug} — {p.display_name}
            </option>
          ))}
        </select>
        {providerLocked && initial?.provider_id && (
          <input type="hidden" name="provider_id" value={initial.provider_id} />
        )}
      </Field>

      <Field
        label="provider_model_id"
        hint="该 provider 自己用的 model 字符串。OpenRouter 用 anthropic/claude-opus-4.5；Anthropic 直连用 claude-opus-4-5-20251022；WorldRouter 看它自己的命名"
      >
        <input
          name="provider_model_id"
          required
          defaultValue={initial?.provider_model_id ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
        />
      </Field>

      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="weight" hint="路由权重，0=备用，正数按比例竞争">
          <input
            name="weight"
            type="number"
            min={0}
            defaultValue={initial?.weight ?? 100}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
          />
        </Field>
        <div className="flex items-end">
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name="enabled"
              defaultChecked={initial?.enabled ?? true}
              className="h-4 w-4"
            />
            启用
          </label>
        </div>
      </div>

      <fieldset className="rounded-lg border p-4">
        <legend className="px-2 text-sm font-medium">价格（USD per 1M tokens）</legend>
        <p className="mb-3 text-xs text-muted-foreground">
          按 provider 的官方价目表填。WorldRouter 七折就把 input/output 各 ×0.7
          填进来；面板会和 OpenRouter 上同模型的价格自动对比，告诉你"七折省了多少"。
        </p>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="input_price (必填)">
            <input
              name="input_price"
              type="number"
              step="0.000001"
              min={0}
              required
              defaultValue={initial?.input_price ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
            />
          </Field>
          <Field label="output_price (必填)">
            <input
              name="output_price"
              type="number"
              step="0.000001"
              min={0}
              required
              defaultValue={initial?.output_price ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
            />
          </Field>
          <Field label="cached_input_price (可选)" hint="读缓存的价，Anthropic 一般 = 0.1× input">
            <input
              name="cached_input_price"
              type="number"
              step="0.000001"
              min={0}
              defaultValue={initial?.cached_input_price ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
            />
          </Field>
          <Field label="cache_write_price (可选)" hint="写缓存的价，Anthropic 一般 = 1.25× input">
            <input
              name="cache_write_price"
              type="number"
              step="0.000001"
              min={0}
              defaultValue={initial?.cache_write_price ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
            />
          </Field>
        </div>
      </fieldset>

      <Field label="备注（可选）">
        <textarea
          name="notes"
          rows={2}
          defaultValue={initial?.notes ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
      </Field>

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
