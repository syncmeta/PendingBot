import type { Context } from 'hono';

// Hono's `c.executionCtx` throws when no ExecutionContext was passed to
// `app.request(...)` — common in vitest fixtures that drive routes
// directly without Workers' runtime around them. Wrap waitUntil so test
// code doesn't have to thread a stub through every call site.
//
// In production this is a 1:1 pass-through. In tests the promise still
// runs (awaited inline) so the side effect lands and assertions can see
// it — just without the runtime's "keep worker alive past Response
// close" guarantee, which tests don't need anyway.

export function safeWaitUntil(c: Context, work: Promise<unknown>): void {
  try {
    c.executionCtx.waitUntil(work);
  } catch {
    // No ExecutionContext (typically vitest). Swallow the rejection so
    // an unhandled-promise-warning doesn't bubble; the work still runs.
    work.catch(() => undefined);
  }
}
