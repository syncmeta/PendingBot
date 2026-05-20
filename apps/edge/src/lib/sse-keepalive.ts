// Periodic SSE keepalive — emit a comment line every KEEPALIVE_INTERVAL_MS
// so idle stretches inside a single turn don't trip client-side inactivity
// timeouts.
//
// Why this exists: OpenAI's server-side built-in tools (image_generation,
// code_interpreter, long web_search) and reasoning models with extended
// thinking can sit for 30–90s without producing a single wire byte.
// URLSession on iOS uses a 60s `timeoutIntervalForRequest` by default,
// which fires when no bytes have arrived in 60s — turning a still-working
// image_generation call into a spurious "timeout" error on the client.
//
// The frame is `:\n\n` — per the SSE spec, lines beginning with `:` are
// comments and MUST be ignored by conforming parsers. ChatStream's hand-
// rolled parser on iOS (handleLine) only branches on `event:` / `data:`,
// so the keepalive is invisible to the rest of the stack.
//
// 15s gives ~4x headroom under iOS's 60s default. AI Gateway and any
// intermediate proxies also benefit from regular traffic on the
// connection.

const KEEPALIVE_INTERVAL_MS = 15_000;
const KEEPALIVE_FRAME = new TextEncoder().encode(': keepalive\n\n');

/**
 * Start emitting an SSE keepalive comment on `controller` every 15s.
 * Returns a stop function — idempotent, safe to call from a `finally`.
 *
 * `isClosed` is consulted before each enqueue so we don't write into a
 * controller the caller has already marked dead but not yet closed.
 */
export function startSseKeepalive(
  controller: ReadableStreamDefaultController<Uint8Array>,
  isClosed: () => boolean,
): () => void {
  let stopped = false;
  const timer = setInterval(() => {
    if (stopped || isClosed()) return;
    try {
      controller.enqueue(KEEPALIVE_FRAME);
    } catch {
      // Controller closed out from under us — stop polling.
      stopped = true;
      clearInterval(timer);
    }
  }, KEEPALIVE_INTERVAL_MS);
  return () => {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
  };
}
