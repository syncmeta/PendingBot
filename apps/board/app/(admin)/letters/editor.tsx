'use client';

import { useActionState } from 'react';
import { savePresetLetter } from './actions';
import type { SaveLetterState } from './_shared';

export function LetterEditor({
  initialTitle,
  initialSummary,
  initialBody,
}: {
  initialTitle: string;
  initialSummary: string;
  initialBody: string;
}) {
  const [state, formAction, pending] = useActionState<SaveLetterState, FormData>(
    savePresetLetter,
    {},
  );

  return (
    <form action={formAction} className="space-y-4">
      <div className="space-y-1">
        <label className="text-sm font-medium">标题</label>
        <input
          name="title"
          defaultValue={initialTitle}
          className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
        <p className="text-xs text-muted-foreground">显示在来信列表封面，越短越好。</p>
      </div>

      <div className="space-y-1">
        <label className="text-sm font-medium">副标题</label>
        <input
          name="summary"
          defaultValue={initialSummary}
          className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
        <p className="text-xs text-muted-foreground">封面上标题下方的一行说明。</p>
      </div>

      <div className="space-y-1">
        <label className="text-sm font-medium">正文（Markdown）</label>
        <textarea
          name="body_md"
          defaultValue={initialBody}
          rows={28}
          spellCheck={false}
          className="w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm leading-relaxed"
        />
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <button
          type="submit"
          disabled={pending}
          className="rounded-md bg-primary px-4 py-1.5 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          {pending ? '保存中…' : '保存'}
        </button>
        {state.error && (
          <span className="text-xs text-destructive">{state.error}</span>
        )}
        {state.ok && !pending && (
          <span className="text-xs text-emerald-700">
            已保存 — 之后注册的新用户会收到这封。
          </span>
        )}
      </div>
    </form>
  );
}
