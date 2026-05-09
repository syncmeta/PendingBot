/**
 * Route Node-side fetch through an HTTP(S) proxy when one is set.
 *
 * Next.js 15 calls `register()` once on Node-runtime startup. We use
 * that hook to install undici's ProxyAgent as the global dispatcher
 * so every server-side fetch — Supabase JS, server actions, anything
 * the app calls out to — picks up the proxy. Node's built-in fetch
 * does not honor `HTTPS_PROXY` / `HTTP_PROXY` on its own, hence this.
 *
 * Honors the standard env-var conventions (upper- and lower-case).
 * No-op if no proxy var is set, so non-proxied envs keep their
 * direct outbound path.
 *
 * macOS users: set `HTTPS_PROXY` in `apps/board/.env.local` to the
 * URL your system proxy exposes (e.g. `http://127.0.0.1:7890`).
 * Next.js will load it before this hook runs.
 */
export async function register() {
  if (process.env.NEXT_RUNTIME !== 'nodejs') return;

  const proxy =
    process.env.HTTPS_PROXY ||
    process.env.https_proxy ||
    process.env.HTTP_PROXY ||
    process.env.http_proxy;
  if (!proxy) return;

  const { setGlobalDispatcher, ProxyAgent } = await import('undici');
  setGlobalDispatcher(new ProxyAgent(proxy));
  console.log(`[board] routing server-side fetch through ${proxy}`);
}
