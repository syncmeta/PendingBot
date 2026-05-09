'use client';

import { useTransition } from 'react';

/// Client wrapper around a server action that needs a JS confirm() before
/// firing — for force-delete and cancel-pending-deletion buttons. Plain
/// `<form action={...}>` would post on first click; we want a single
/// "are you sure" gate without pulling a whole modal library.
export function ConfirmDeletionAction({
  action,
  userId,
  confirmText,
  label,
  pendingLabel,
  variant = 'destructive',
  size = 'md',
}: {
  action: (userId: string) => Promise<void>;
  userId: string;
  confirmText: string;
  label: string;
  pendingLabel: string;
  variant?: 'destructive' | 'normal';
  size?: 'sm' | 'md';
}) {
  const [pending, startTransition] = useTransition();
  const onClick = () => {
    if (!window.confirm(confirmText)) return;
    startTransition(() => {
      action(userId);
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
