'use client';

import { useActionState, useState } from 'react';
import { useFormErrorToast } from '@/components/use-form-error-toast';
import type { ToolFormState } from './actions';

export type ToolFormValues = {
  key?: string;
  kind?: string;
  mcp_server_id?: string | null;
  scopes?: string[];
  description?: string | null;
  model_description?: string | null;
  enabled?: boolean;
  notes?: string | null;
};

export type McpServerOption = { id: string; name: string };

export function ToolForm({
  action,
  initial,
  servers,
  submitLabel,
  lockedKey,
}: {
  action: (prev: ToolFormState, formData: FormData) => Promise<ToolFormState>;
  initial?: ToolFormValues;
  servers: McpServerOption[];
  submitLabel: string;
  lockedKey?: boolean;
}) {
  const [state, formAction, pending] = useActionState<ToolFormState, FormData>(action, {});
  useFormErrorToast(state.error);

  // kind drives whether the MCP-server picker shows. We mirror the DB
  // consistency constraint (native → no server, mcp → server required)
  // by collapsing the picker for native tools.
  const [kind, setKind] = useState<string>(initial?.kind ?? 'native');
  const initialScopes = initial?.scopes ?? ['chat'];

  return (
    <form action={formAction} className="space-y-4">
      <Field label="key" hint="LLM 看到的 function.name —— 小写字母 / 数字 / 下划线，如 query_user_memory">
        <input
          name="key"
          required
          defaultValue={initial?.key ?? ''}
          readOnly={lockedKey}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm read-only:bg-muted"
        />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="kind">
          <select
            name="kind"
            value={kind}
            onChange={(e) => setKind(e.target.value)}
            className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="native">native（代码实现）</option>
            <option value="mcp">mcp（来自 MCP server）</option>
          </select>
        </Field>
        {kind === 'mcp' && (
          <Field label="MCP server" hint="哪个上游 server 提供这个工具">
            <select
              name="mcp_server_id"
              defaultValue={initial?.mcp_server_id ?? ''}
              className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="">— 选一个 —</option>
              {servers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </Field>
        )}
      </div>
      <Field label="scopes" hint="工具出现在哪些组装路径：chat = bot 回复，envelope = 写信">
        <div className="flex gap-4">
          {(['chat', 'envelope'] as const).map((s) => (
            <label key={s} className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="scopes"
                value={s}
                defaultChecked={initialScopes.includes(s)}
                className="h-4 w-4"
              />
              <span className="font-mono text-xs">{s}</span>
            </label>
          ))}
        </div>
      </Field>
      <Field label="说明（可选）" hint="给 Board 列表看的人看的描述，不进模型">
        <input
          name="description"
          defaultValue={initial?.description ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
      </Field>
      <Field
        label={kind === 'native' ? '模型描述（必填）' : '模型描述（可选）'}
        hint={
          kind === 'native'
            ? 'LLM 实际看到的 function.description —— native 工具没有代码默认值，这一栏就是描述本身。改动 ~1 分钟内对模型生效，不需部署。'
            : 'LLM 实际看到的 function.description。留空 = 用上游 MCP server 的描述。改动 ~1 分钟内生效，不需部署。'
        }
      >
        <textarea
          name="model_description"
          rows={6}
          required={kind === 'native'}
          defaultValue={initial?.model_description ?? ''}
          className="block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
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

      <p className="text-xs text-muted-foreground">
        native 工具的运行时实现仍在 edge 代码里（<code className="font-mono">apps/edge/src/lib/bot-reply/tools/*</code>）——
        这张表只是"是否暴露 + 在哪个 surface"的过滤层，新增一行不会凭空给模型一个没实现的工具。
      </p>
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
