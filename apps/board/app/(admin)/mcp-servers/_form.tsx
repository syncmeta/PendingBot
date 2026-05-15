'use client';

import { useActionState, useState } from 'react';
import { useFormErrorToast } from '@/components/use-form-error-toast';
import type { McpServerFormState } from './actions';

export type McpServerFormValues = {
  name?: string;
  url?: string;
  transport?: string;
  auth_kind?: string;
  auth_header_name?: string | null;
  secret_ref?: string | null;
  enabled?: boolean;
  notes?: string | null;
};

export function McpServerForm({
  action,
  initial,
  submitLabel,
  lockedName,
}: {
  action: (prev: McpServerFormState, formData: FormData) => Promise<McpServerFormState>;
  initial?: McpServerFormValues;
  submitLabel: string;
  lockedName?: boolean;
}) {
  const [state, formAction, pending] = useActionState<McpServerFormState, FormData>(
    action,
    {},
  );
  useFormErrorToast(state.error);

  // auth_kind drives whether header / secret fields are required. We
  // mirror this in the UI by collapsing them when 'none' is selected,
  // matching what the DB constraint enforces.
  const [authKind, setAuthKind] = useState<string>(initial?.auth_kind ?? 'none');

  return (
    <form action={formAction} className="space-y-4">
      <Field label="name" hint="路由器代码里用的稳定标识，如 exa / tavily — 小写字母 / 数字 / 短横线">
        <input
          name="name"
          required
          defaultValue={initial?.name ?? ''}
          readOnly={lockedName}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm read-only:bg-muted"
        />
      </Field>
      <Field label="url" hint="MCP endpoint，如 https://mcp.exa.ai/mcp">
        <input
          name="url"
          required
          type="url"
          defaultValue={initial?.url ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
        />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="transport">
          <select
            name="transport"
            defaultValue={initial?.transport ?? 'http'}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="http">http (Streamable HTTP)</option>
            <option value="sse">sse (legacy)</option>
          </select>
        </Field>
        <Field label="auth_kind">
          <select
            name="auth_kind"
            value={authKind}
            onChange={(e) => setAuthKind(e.target.value)}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="none">none</option>
            <option value="header">header</option>
          </select>
        </Field>
      </div>
      {authKind === 'header' && (
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="auth_header_name" hint="如 x-api-key 或 authorization">
            <input
              name="auth_header_name"
              defaultValue={initial?.auth_header_name ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
            />
          </Field>
          <Field
            label="secret_ref"
            hint="Wrangler env var 名，如 EXA_API_KEY；密钥本体不入库"
          >
            <input
              name="secret_ref"
              defaultValue={initial?.secret_ref ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
            />
          </Field>
        </div>
      )}
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
