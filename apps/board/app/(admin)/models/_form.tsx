'use client';

import { useActionState } from 'react';
import { useFormErrorToast } from '@/components/use-form-error-toast';
import type { ModelFormState } from './actions';

export type ModelFormValues = {
  slug?: string;
  display_name?: string;
  family?: string | null;
  context_window?: number | null;
  max_output_tokens?: number | null;
  capabilities?: Record<string, unknown> | null;
  openrouter_canonical_slug?: string | null;
  enabled?: boolean;
  deprecated_at?: string | null;
  notes?: string | null;
};

const CAPS = [
  { key: 'vision', label: 'Vision (图片输入)' },
  { key: 'tool_use', label: 'Tool use / function calling' },
  { key: 'prompt_cache', label: 'Prompt caching (Anthropic-style)' },
  { key: 'reasoning', label: 'Reasoning / thinking tokens' },
  { key: 'json_mode', label: 'JSON mode' },
] as const;

export function ModelForm({
  action,
  initial,
  submitLabel,
}: {
  action: (prev: ModelFormState, formData: FormData) => Promise<ModelFormState>;
  initial?: ModelFormValues;
  submitLabel: string;
}) {
  const [state, formAction, pending] = useActionState<ModelFormState, FormData>(action, {});
  useFormErrorToast(state.error);
  const caps = (initial?.capabilities ?? {}) as Record<string, unknown>;

  return (
    <form action={formAction} className="space-y-4">
      <Field
        label="slug"
        hint="canonical 标识，bots.model_id 引用它。常见做法：vendor 不带，模型名带版本，如 claude-opus-4.5 / gpt-5 / deepseek-v4-pro"
      >
        <input
          name="slug"
          required
          defaultValue={initial?.slug ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
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
      <Field label="family（可选）" hint="同代模型分组，如 claude-4 / gpt-5">
        <input
          name="family"
          defaultValue={initial?.family ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
      </Field>
      <Field
        label="OpenRouter canonical slug（可选）"
        hint="OpenRouter catalog 上的 id，例如 anthropic/claude-haiku-4.5。设了之后 /models/sync 会按这个 id 从 OpenRouter 拉 context_window / max_output / capabilities 覆盖到本表。留空表示这条模型不走 OpenRouter sync。"
      >
        <input
          name="openrouter_canonical_slug"
          defaultValue={initial?.openrouter_canonical_slug ?? ''}
          placeholder="anthropic/claude-haiku-4.5"
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
        />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="context_window（tokens，可选）">
          <input
            name="context_window"
            type="number"
            defaultValue={initial?.context_window ?? ''}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
          />
        </Field>
        <Field label="max_output_tokens（可选）">
          <input
            name="max_output_tokens"
            type="number"
            defaultValue={initial?.max_output_tokens ?? ''}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
          />
        </Field>
      </div>
      <Field label="capabilities">
        <div className="grid gap-2 sm:grid-cols-2">
          {CAPS.map((c) => (
            <label key={c.key} className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name={`cap_${c.key}`}
                defaultChecked={caps[c.key] === true}
                className="h-4 w-4"
              />
              {c.label}
            </label>
          ))}
        </div>
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
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          name="deprecated"
          defaultChecked={!!initial?.deprecated_at}
          className="h-4 w-4"
        />
        标记为已废弃 (deprecated_at = now)
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
