'use client';

import { useState, useTransition } from 'react';
import { useToast } from '@/components/toast';
import { updateToolModelDescription } from './actions';

// Inline editor for tools.model_description on the Tools list page.
// Lets every tool's model-facing description be browsed AND edited in
// place — no need to open the per-tool edit form. Save is gated on the
// textarea being dirty; an empty save clears the override so the edge
// runtime falls back to the code / upstream default.
export function ModelDescriptionCell({
  id,
  initial,
  placeholder,
}: {
  id: string;
  initial: string | null;
  placeholder: string;
}) {
  const [value, setValue] = useState(initial ?? '');
  const [saved, setSaved] = useState(initial ?? '');
  const [pending, startTransition] = useTransition();
  const { push } = useToast();

  const dirty = value !== saved;

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
          disabled={!dirty || pending}
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
        {dirty && <span className="text-xs text-amber-600">未保存</span>}
        {!value.trim() && !dirty && (
          <span className="text-xs text-muted-foreground">用默认描述</span>
        )}
      </div>
    </div>
  );
}
