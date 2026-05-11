'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useToast } from './toast';

export type ActionResult = {
  ok?: true;
  error?: string;
  /// Optional message shown in the success toast. Defaults to `successMessage` prop.
  message?: string;
};

/// Generic button that runs a server action and surfaces all four UX
/// states the board promises:
///   1. pending — button disabled, label switches to `pendingLabel`
///   2. success — green toast with `message` (or default `successMessage`)
///   3. error   — red toast with `error`
///   4. refresh — `useTransition` keeps `isPending` true until the
///                server-side `revalidatePath` + re-render completes, so
///                the button stays in its loading state through the
///                "等响应" window.
///
/// For destructive actions, set `confirmText` to gate the call behind a
/// window.confirm.
///
/// On success the wrapper either pushes to `successHref` (e.g. when the
/// current page disappears, like force-delete on /users/<id>) or just
/// lets the `revalidatePath` in the action drive the re-render. We do
/// NOT call router.refresh() — the action's revalidatePath already
/// invalidates the route, and an extra refresh would double-fetch.
export function ActionButton<Args extends unknown[]>({
  action,
  args = [] as unknown as Args,
  label,
  pendingLabel,
  successMessage,
  confirmText,
  successHref,
  variant = 'normal',
  size = 'md',
  title,
  className,
}: {
  action: (...args: Args) => Promise<ActionResult | void>;
  args?: Args;
  label: React.ReactNode;
  pendingLabel?: React.ReactNode;
  successMessage?: string;
  confirmText?: string;
  successHref?: string;
  variant?: 'normal' | 'destructive' | 'primary';
  size?: 'sm' | 'md';
  title?: string;
  className?: string;
}) {
  const [pending, startTransition] = useTransition();
  const router = useRouter();
  const { push } = useToast();

  const onClick = () => {
    if (confirmText && !window.confirm(confirmText)) return;
    startTransition(async () => {
      let res: ActionResult | void;
      try {
        res = await action(...args);
      } catch (e) {
        push({
          kind: 'error',
          message: e instanceof Error ? e.message : '操作失败',
        });
        return;
      }
      if (res && res.error) {
        push({ kind: 'error', message: res.error });
        return;
      }
      // Treat undefined return as success (existing actions that just
      // revalidatePath without returning anything still get a toast).
      const msg = (res && res.message) ?? successMessage ?? '操作成功';
      push({ kind: 'success', message: msg });
      if (successHref) router.push(successHref);
    });
  };

  const sizeCls = size === 'sm' ? 'px-2 py-1 text-xs' : 'px-3 py-1.5 text-sm';
  const variantCls =
    variant === 'destructive'
      ? 'border border-destructive/50 bg-destructive/10 text-destructive hover:bg-destructive/15'
      : variant === 'primary'
        ? 'bg-primary text-primary-foreground hover:opacity-90'
        : 'border border-input bg-background hover:bg-accent';
  const cls = [
    'rounded-md font-medium disabled:opacity-50',
    sizeCls,
    variantCls,
    className ?? '',
  ].join(' ');

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={pending}
      className={cls}
      title={title}
    >
      {pending ? (pendingLabel ?? '处理中…') : label}
    </button>
  );
}
