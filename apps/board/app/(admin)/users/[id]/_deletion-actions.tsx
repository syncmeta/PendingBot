'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';

type Result = { ok?: true; error?: string };

/// Client wrapper around a server action that needs a JS confirm() before
/// firing — for force-delete and cancel-pending-deletion buttons. Plain
/// `<form action={...}>` would post on first click; we want a single
/// "are you sure" gate without pulling a whole modal library.
///
/// The action returns { ok } | { error }. On error we alert the message
/// (otherwise the button looks dead — the most recent bug was a silently
/// swallowed RPC error that made "立即注销" appear to do nothing). On
/// success we refresh the route so the user-list reflects the deletion.
export function ConfirmDeletionAction({
  action,
  userId,
  confirmText,
  label,
  pendingLabel,
  variant = 'destructive',
  size = 'md',
  successHref,
}: {
  action: (userId: string) => Promise<Result>;
  userId: string;
  confirmText: string;
  label: string;
  pendingLabel: string;
  variant?: 'destructive' | 'normal';
  size?: 'sm' | 'md';
  /// Where to navigate on success. Defaults to router.refresh() in place
  /// — fine for cancel-pending. For force-delete from /users/<id> pass
  /// '/users' so the user doesn't land on a 404 of their own deletion.
  successHref?: string;
}) {
  const [pending, startTransition] = useTransition();
  const router = useRouter();
  const onClick = () => {
    if (!window.confirm(confirmText)) return;
    startTransition(async () => {
      const res = await action(userId);
      if (res?.error) {
        window.alert(`操作失败：${res.error}`);
        return;
      }
      if (successHref) router.push(successHref);
      else router.refresh();
    });
  };
  const sizeCls = size === 'sm' ? 'px-2 py-1 text-xs' : 'px-3 py-1.5 text-sm';
  const cls =
    variant === 'destructive'
      ? `rounded-md border border-destructive/40 bg-destructive/10 ${sizeCls} font-medium text-destructive hover:bg-destructive/15 disabled:opacity-50`
      : `rounded-md border border-input bg-background ${sizeCls} hover:bg-accent disabled:opacity-50`;
  return (
    <button type="button" onClick={onClick} disabled={pending} className={cls}>
      {pending ? pendingLabel : label}
    </button>
  );
}
