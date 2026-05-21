'use client';

import { useActionState, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { savePrompt, resetPrompt, commitPrompt } from '../../actions';
import type { CommitPromptResult, SavePromptState } from '../../_shared';

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
  const [commitPending, startCommit] = useTransition();
  const [commitResult, setCommitResult] = useState<CommitPromptResult | null>(
    null,
  );

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
          <button
            type="button"
            disabled={commitPending}
            onClick={() => {
              setCommitResult(null);
              startCommit(async () => {
                const r = await commitPrompt(name, locale);
                setCommitResult(r);
                router.refresh();
              });
            }}
            className="rounded-md border border-input px-3 py-1.5 text-sm hover:bg-accent disabled:opacity-50"
          >
            {commitPending ? '提交中…' : '提交到 git'}
          </button>
          {state.error && (
            <span className="text-xs text-destructive">{state.error}</span>
          )}
          {commitResult?.ok && commitResult.committed && (
            <span className="text-xs text-emerald-700">
              已提交 <code>{commitResult.sha}</code>
            </span>
          )}
          {commitResult?.ok && !commitResult.committed && (
            <span className="text-xs text-muted-foreground">
              git 无改动可提交
            </span>
          )}
          {commitResult && !commitResult.ok && (
            <span className="text-xs text-destructive">
              提交失败：{commitResult.error}
            </span>
          )}
          {state.ok && !pending && (
            <span className="text-xs text-emerald-700">已保存 — edge 缓存 ≤ 30s 内刷新</span>
          )}
          {state.ok && !pending && state.bundled?.ok && (
            <span className="text-xs text-emerald-700">
              已写入 <code>{state.bundled.path}</code>（点"提交到 git"入库）
            </span>
          )}
          {state.ok && !pending && state.bundled && !state.bundled.ok && (
            <span className="text-xs text-amber-600">
              bundled .md 未写入：{state.bundled.error}
            </span>
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
