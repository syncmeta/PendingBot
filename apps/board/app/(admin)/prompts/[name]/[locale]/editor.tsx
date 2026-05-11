'use client';

import { useActionState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { savePrompt, resetPrompt, type SavePromptState } from '../../actions';

export function PromptEditor({
  name,
  locale,
  initialBody,
  overrideVersion,
  bundledBody,
}: {
  name: string;
  locale: string;
  initialBody: string;
  overrideVersion: number | null;
  bundledBody: string;
}) {
  const router = useRouter();
  const [state, formAction, pending] = useActionState<SavePromptState, FormData>(
    savePrompt,
    {},
  );
  const [resetPending, startReset] = useTransition();

  return (
    <div className="space-y-4">
      <form action={formAction} className="space-y-3">
        <input type="hidden" name="name" value={name} />
        <input type="hidden" name="locale" value={locale} />
        <textarea
          name="body_md"
          defaultValue={initialBody}
          rows={28}
          spellCheck={false}
          className="w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm leading-relaxed"
        />
        <div className="flex flex-wrap items-center gap-3">
          <button
            type="submit"
            disabled={pending}
            className="rounded-md bg-primary px-4 py-1.5 text-sm font-medium text-primary-foreground disabled:opacity-50"
          >
            {pending ? '保存中…' : '保存'}
          </button>
          {overrideVersion != null && (
            <button
              type="button"
              disabled={resetPending}
              onClick={() => {
                if (
                  !window.confirm(
                    `把 ${name}/${locale} 重置为 bundled 默认？当前覆盖将删除（admin_audit 会留底）。`,
                  )
                )
                  return;
                startReset(async () => {
                  await resetPrompt(name, locale);
                  router.refresh();
                });
              }}
              className="rounded-md border border-input px-3 py-1.5 text-sm hover:bg-accent disabled:opacity-50"
            >
              {resetPending ? '重置中…' : '重置为 bundled'}
            </button>
          )}
          {state.error && (
            <span className="text-xs text-destructive">{state.error}</span>
          )}
          {state.ok && !pending && (
            <span className="text-xs text-emerald-700">已保存 — edge 缓存 ≤ 30s 内刷新</span>
          )}
        </div>
      </form>

      {overrideVersion == null && (
        <p className="text-xs text-muted-foreground">
          当前未覆盖，文本框里是仓库 bundled 默认（直接保存即变成覆盖）。
        </p>
      )}

      <details className="rounded-md border bg-muted/30 p-3">
        <summary className="cursor-pointer text-xs text-muted-foreground">
          查看 bundled 默认（{name}/{locale}）
        </summary>
        <pre className="mt-2 whitespace-pre-wrap break-words text-xs leading-relaxed">
          {bundledBody}
        </pre>
      </details>
    </div>
  );
}
