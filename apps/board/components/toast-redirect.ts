// Server-safe slice of the toast module: pure URL builders used by
// server actions to attach flash params to redirect targets. Lives in
// its own .ts (no JSX, no React imports, no 'use client' directive) so
// server actions can import these without Next.js's client/server
// boundary tripping on the rest of toast.tsx.
//
// Companion to components/toast.tsx — that file's 'use client' covers
// the Provider / Reader / Viewport React components, none of which a
// server action ever needs.

export type ToastKind = 'success' | 'error' | 'info';

/// Build a redirect URL with flash params. Pure string-building.
/// Server actions call `redirect(withFlash('/foo', '已保存'))`; the
/// FlashToastReader on the page side picks the params up, fires a
/// toast, then strips them from the URL.
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
