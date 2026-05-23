'use client';

import { useActionState } from 'react';
import { savePresetConversation, savePresetGroup } from './actions';
import { formatJson, type SavePresetState } from './_shared';

type ConversationTemplate = {
  slug: string;
  bot_slug: string;
  title: string;
  base_ts: string;
  messages: unknown;
  sort_order: number;
  enabled: boolean;
};

type GroupTemplate = {
  slug: string;
  title: string;
  bot_slugs: string[];
  join_policy: 'scan_open' | 'approval' | 'closed';
  messages: unknown;
  sort_order: number;
  enabled: boolean;
};

export function PresetConversationForm({
  row,
}: {
  row: ConversationTemplate;
}) {
  const [state, action, pending] = useActionState<SavePresetState, FormData>(
    savePresetConversation,
    {},
  );

  return (
    <form action={action} className="rounded-md border bg-card p-4 space-y-3">
      <div className="grid gap-3 md:grid-cols-[1fr_1fr_90px_auto]">
        <Field label="slug" name="slug" defaultValue={row.slug} />
        <Field label="bot slug" name="bot_slug" defaultValue={row.bot_slug} />
        <Field label="排序" name="sort_order" defaultValue={String(row.sort_order)} />
        <label className="flex items-end gap-2 pb-2 text-sm">
          <input name="enabled" type="checkbox" defaultChecked={row.enabled} />
          启用
        </label>
      </div>
      <Field label="标题" name="title" defaultValue={row.title} />
      <Field label="起始时间" name="base_ts" defaultValue={row.base_ts} />
      <Textarea label="消息 JSON" name="messages" defaultValue={formatJson(row.messages)} rows={12} />
      <SubmitRow pending={pending} state={state} slug={row.slug} />
    </form>
  );
}

export function PresetGroupForm({ row }: { row: GroupTemplate }) {
  const [state, action, pending] = useActionState<SavePresetState, FormData>(
    savePresetGroup,
    {},
  );

  return (
    <form action={action} className="rounded-md border bg-card p-4 space-y-3">
      <div className="grid gap-3 md:grid-cols-[1fr_1fr_90px_auto]">
        <Field label="slug" name="slug" defaultValue={row.slug} />
        <Field label="bot slugs" name="bot_slugs" defaultValue={row.bot_slugs.join(', ')} />
        <Field label="排序" name="sort_order" defaultValue={String(row.sort_order)} />
        <label className="flex items-end gap-2 pb-2 text-sm">
          <input name="enabled" type="checkbox" defaultChecked={row.enabled} />
          启用
        </label>
      </div>
      <Field label="标题" name="title" defaultValue={row.title} />
      <label className="block space-y-1">
        <span className="text-sm font-medium">加群方式</span>
        <select
          name="join_policy"
          defaultValue={row.join_policy}
          className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        >
          <option value="approval">审批后进</option>
          <option value="scan_open">扫码即进</option>
          <option value="closed">关闭</option>
        </select>
      </label>
      <Textarea label="消息 JSON" name="messages" defaultValue={formatJson(row.messages)} rows={10} />
      <SubmitRow pending={pending} state={state} slug={row.slug} />
    </form>
  );
}

function Field({
  label,
  name,
  defaultValue,
}: {
  label: string;
  name: string;
  defaultValue: string;
}) {
  return (
    <label className="block space-y-1">
      <span className="text-sm font-medium">{label}</span>
      <input
        name={name}
        defaultValue={defaultValue}
        className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
      />
    </label>
  );
}

function Textarea({
  label,
  name,
  defaultValue,
  rows,
}: {
  label: string;
  name: string;
  defaultValue: string;
  rows: number;
}) {
  return (
    <label className="block space-y-1">
      <span className="text-sm font-medium">{label}</span>
      <textarea
        name={name}
        defaultValue={defaultValue}
        rows={rows}
        spellCheck={false}
        className="w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm leading-relaxed"
      />
    </label>
  );
}

function SubmitRow({
  pending,
  state,
  slug,
}: {
  pending: boolean;
  state: SavePresetState;
  slug: string;
}) {
  const showState = state.slug === slug || (!state.slug && slug === '');
  return (
    <div className="flex flex-wrap items-center gap-3">
      <button
        type="submit"
        disabled={pending}
        className="rounded-md bg-primary px-4 py-1.5 text-sm font-medium text-primary-foreground disabled:opacity-50"
      >
        {pending ? '保存中…' : '保存'}
      </button>
      {showState && state.error && (
        <span className="text-xs text-destructive">{state.error}</span>
      )}
      {showState && state.ok && !pending && (
        <span className="text-xs text-emerald-700">已保存</span>
      )}
    </div>
  );
}
