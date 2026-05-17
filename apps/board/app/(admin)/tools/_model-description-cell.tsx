'use client';

import { useState, useTransition } from 'react';
import { useToast } from '@/components/toast';
import { updateToolModelDescription } from './actions';

// Inline editor for tools.model_description on the Tools list page.
// Lets every tool's model-facing description be browsed AND edited in
// place — no need to open the per-tool edit form. Save is gated on the
// textarea being dirty. For native tools the description is the single
// source of truth (no code default), so an empty save is blocked; MCP
// tools may be cleared to fall back to the upstream server's description.
export function ModelDescriptionCell({
  id,
  kind,
  initial,
  placeholder,
}: {
  id: string;
  kind: 'native' | 'mcp' | string;
  initial: string | null;
  placeholder: string;
}) {
  const [value, setValue] = useState(initial ?? '');
  const [saved, setSaved] = useState(initial ?? '');
  const [pending, startTransition] = useTransition();
  const { push } = useToast();

  const dirty = value !== saved;
  // Native tools must keep a non-empty description — the DB CHECK and the
  // server action both reject an empty value, so block the save up front.
  const emptyNative = kind === 'native' && !value.trim();

  const save = () => {
    startTransition(async () => {
      const res = await updateToolModelDescription(id, value);
      if (res?.error) {
        push({ kind: 'error', message: res.error });
        return;
      }
      setSaved(value);
      push({ kind: 'success', message: res?.message ?? '已保存' });
    });
  };

  return (
    <div className="space-y-1.5">
      <textarea
        value={value}
        onChange={(e) => setValue(e.target.value)}
        rows={5}
        placeholder={placeholder}
        className="block w-full rounded-md border border-input bg-background px-2.5 py-1.5 font-mono text-xs leading-relaxed"
      />
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={save}
          disabled={!dirty || pending || emptyNative}
          className="rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground disabled:opacity-40"
        >
          {pending ? '保存中…' : '保存'}
        </button>
        {dirty && !pending && (
          <button
            type="button"
            onClick={() => setValue(saved)}
            className="rounded-md border border-input px-2.5 py-1 text-xs hover:bg-accent"
          >
            还原
          </button>
        )}
        {dirty && !emptyNative && <span className="text-xs text-amber-600">未保存</span>}
        {emptyNative && (
          <span className="text-xs text-destructive">native 工具必须有描述</span>
        )}
        {kind === 'mcp' && !value.trim() && !dirty && (
          <span className="text-xs text-muted-foreground">用上游描述</span>
        )}
      </div>
    </div>
  );
}
