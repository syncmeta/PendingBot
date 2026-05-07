'use client';

import { useActionState } from 'react';
import type { RuleFormState } from './actions';

// task_types currently emitted by the router callers. Keep this in
// sync with apps/edge/src/lib/* — adding here is harmless (just shows
// the option in the dropdown), but missing entries force the user to
// type free-form which is error-prone.
const KNOWN_TASKS = [
  'message_reply',
  'title',
  'lookback',
  'review',
  'scroll',
  'bot_note',
] as const;

export type RuleFormValues = {
  task_type?: string;
  match_priority?: number;
  enabled?: boolean;
  override_model_id?: string | null;
  prefer_provider_id?: string | null;
  notes?: string | null;
};

export type ModelOption = { id: string; slug: string; display_name: string };
export type ProviderOption = { id: string; slug: string; display_name: string };

export function RuleForm({
  action,
  initial,
  models,
  providers,
  submitLabel,
}: {
  action: (prev: RuleFormState, formData: FormData) => Promise<RuleFormState>;
  initial?: RuleFormValues;
  models: ModelOption[];
  providers: ProviderOption[];
  submitLabel: string;
}) {
  const [state, formAction, pending] = useActionState<RuleFormState, FormData>(action, {});
  const taskValue = initial?.task_type ?? '';
  const taskInList = KNOWN_TASKS.includes(taskValue as (typeof KNOWN_TASKS)[number]);

  return (
    <form action={formAction} className="space-y-4">
      <Field
        label="task_type"
        hint="必须和 router 调用方传的 taskType 一致——目前 6 个内置；新加的 task 也可手填"
      >
        <input
          name="task_type"
          required
          list="task-types"
          defaultValue={taskValue}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
        />
        <datalist id="task-types">
          {KNOWN_TASKS.map((t) => (
            <option key={t} value={t} />
          ))}
          {!taskInList && taskValue && <option value={taskValue} />}
        </datalist>
      </Field>

      <Field
        label="match_priority"
        hint="同一 task_type 下多条规则时，priority 最小的 enabled 行胜出。100 是建议默认；0–10 留给紧急覆盖"
      >
        <input
          name="match_priority"
          type="number"
          min={0}
          defaultValue={initial?.match_priority ?? 100}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 tabular-nums"
        />
      </Field>

      <Field
        label="override_model_id（可选）"
        hint="把这个 task 的 model 强制换成下面的 canonical model。留「不覆盖」则用 bot 自己选的 model"
      >
        <select
          name="override_model_id"
          defaultValue={initial?.override_model_id ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        >
          <option value="">— 不覆盖 —</option>
          {models.map((m) => (
            <option key={m.id} value={m.id}>
              {m.slug} — {m.display_name}
            </option>
          ))}
        </select>
      </Field>

      <Field
        label="prefer_provider_id（可选）"
        hint="alias 选择时偏好这个 provider。留「无偏好」则按 alias weight 走"
      >
        <select
          name="prefer_provider_id"
          defaultValue={initial?.prefer_provider_id ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        >
          <option value="">— 无偏好 —</option>
          {providers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.slug} — {p.display_name}
            </option>
          ))}
        </select>
      </Field>

      <Field label="备注（可选）">
        <textarea
          name="notes"
          rows={2}
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
