// Centralised env access. Vite inlines `import.meta.env.VITE_*` at build time;
// these come from `.env` locally and Cloudflare Pages env vars in prod.
// Fail loud at module load if a required var is missing — better than a
// confusing 401/CORS error deep in a request.

function required(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(
      `[admin] missing required env var ${name}. ` +
        `Set it in .env (local) or Cloudflare Pages env (prod). See .env.example.`,
    );
  }
  return value;
}

// Edge base, no trailing slash. All routes are <EDGE_API_URL>/v1/*.
export const EDGE_API_URL = required(
  'VITE_EDGE_API_URL',
  import.meta.env.VITE_EDGE_API_URL,
).replace(/\/+$/, '');

export const SUPABASE_URL = required('VITE_SUPABASE_URL', import.meta.env.VITE_SUPABASE_URL);
export const SUPABASE_PUBLISHABLE_KEY = required(
  'VITE_SUPABASE_PUBLISHABLE_KEY',
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
);
