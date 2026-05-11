'use client';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { useRouter, useSearchParams } from 'next/navigation';

// Tiny zero-dep toast system. One Provider mounted in the (admin) layout
// exposes `useToast().push({ kind, message })` to every client component.
// Toasts auto-dismiss after 4s; click X to close earlier. Capped at 5
// visible so a runaway loop doesn't paper over the screen.

export type ToastKind = 'success' | 'error' | 'info';

export type Toast = {
  id: number;
  kind: ToastKind;
  message: string;
};

type Ctx = {
  push: (t: Omit<Toast, 'id'>) => void;
};

const ToastCtx = createContext<Ctx | null>(null);
const MAX_VISIBLE = 5;
const AUTO_DISMISS_MS = 4000;

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextIdRef = useRef(1);

  const push = useCallback((t: Omit<Toast, 'id'>) => {
    const id = nextIdRef.current++;
    setToasts((prev) => [...prev.slice(-(MAX_VISIBLE - 1)), { ...t, id }]);
    setTimeout(() => {
      setToasts((prev) => prev.filter((x) => x.id !== id));
    }, AUTO_DISMISS_MS);
  }, []);

  const dismiss = useCallback((id: number) => {
    setToasts((prev) => prev.filter((x) => x.id !== id));
  }, []);

  const value = useMemo<Ctx>(() => ({ push }), [push]);

  return (
    <ToastCtx.Provider value={value}>
      {children}
      <Viewport toasts={toasts} dismiss={dismiss} />
    </ToastCtx.Provider>
  );
}

export function useToast(): Ctx {
  const ctx = useContext(ToastCtx);
  if (!ctx) throw new Error('useToast must be used inside <ToastProvider>');
  return ctx;
}

function Viewport({
  toasts,
  dismiss,
}: {
  toasts: Toast[];
  dismiss: (id: number) => void;
}) {
  if (toasts.length === 0) return null;
  return (
    <div
      role="region"
      aria-label="通知"
      className="pointer-events-none fixed inset-x-0 bottom-4 z-50 flex flex-col items-center gap-2 px-4"
    >
      {toasts.map((t) => (
        <div
          key={t.id}
          role={t.kind === 'error' ? 'alert' : 'status'}
          className={`pointer-events-auto flex w-full max-w-md items-start gap-3 rounded-md border px-3 py-2 text-sm shadow-md ${
            t.kind === 'success'
              ? 'border-emerald-500/40 bg-emerald-50 text-emerald-900'
              : t.kind === 'error'
                ? 'border-destructive/50 bg-destructive/10 text-destructive'
                : 'border-input bg-card text-foreground'
          }`}
        >
          <span className="flex-1 whitespace-pre-wrap break-words">
            {t.message}
          </span>
          <button
            type="button"
            onClick={() => dismiss(t.id)}
            aria-label="关闭"
            className="-mr-1 -mt-0.5 rounded px-1 text-xs text-muted-foreground hover:bg-black/5"
          >
            ✕
          </button>
        </div>
      ))}
    </div>
  );
}

/// Reads ?toast=<msg>&toastKind=<kind> from the URL, fires one toast,
/// then strips the params so a refresh doesn't replay it. Used by
/// redirect-based form flows (create/update) — server action calls
/// `redirect('/foo?toast=已保存&toastKind=success')`, this component
/// then pushes the toast and cleans the URL.
export function FlashToastReader() {
  const router = useRouter();
  const sp = useSearchParams();
  const { push } = useToast();
  const fired = useRef<string | null>(null);

  useEffect(() => {
    const msg = sp.get('toast');
    if (!msg) return;
    // Guard against StrictMode double-invoke + against re-firing if
    // some other state change re-runs this effect with the same params.
    const sig = `${msg}|${sp.get('toastKind') ?? ''}`;
    if (fired.current === sig) return;
    fired.current = sig;

    const rawKind = sp.get('toastKind');
    const kind: ToastKind =
      rawKind === 'success' || rawKind === 'error' || rawKind === 'info'
        ? rawKind
        : 'success';
    push({ kind, message: msg });

    // Strip the flash params without adding a history entry.
    const next = new URLSearchParams(sp.toString());
    next.delete('toast');
    next.delete('toastKind');
    const qs = next.toString();
    router.replace(qs ? `?${qs}` : window.location.pathname, { scroll: false });
  }, [sp, push, router]);

  return null;
}

/// Helper for server actions: build a redirect URL with flash params.
/// Pure string-building, safe to import in server-only files.
export function withFlash(
  path: string,
  message: string,
  kind: ToastKind = 'success',
): string {
  const u = new URL(path, 'http://_local');
  u.searchParams.set('toast', message);
  u.searchParams.set('toastKind', kind);
  return u.pathname + (u.search ? u.search : '');
}
