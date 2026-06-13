// Centralised env access. Vite inlines `import.meta.env.VITE_*` at build time;
// these come from `.env` locally and the worker's wrangler config in prod
// (the SPA is bundled into the edge worker's assets — see apps/edge).
// Fail loud at module load if a required var is missing.
//
// Auth is handled by Cloudflare Access (same-origin cookie), so the board no
// longer needs Supabase Auth or a Turnstile key — EDGE_API_URL is the only
// config it carries.

function required(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(
      `[admin] missing required env var ${name}. ` +
        `Set it in .env (local) or the build env (prod). See .env.example.`,
    );
  }
  return value;
}

// Edge base, no trailing slash. All routes are <EDGE_API_URL>/v1/*. Same origin
// as the board page (bot.pendingname.com) so the Access cookie rides along.
export const EDGE_API_URL = required(
  'VITE_EDGE_API_URL',
  import.meta.env.VITE_EDGE_API_URL,
).replace(/\/+$/, '');
