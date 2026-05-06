// Shape of the Cloudflare Worker bindings + secrets that every request handler
// receives via `c.env`. Mirrors wrangler.jsonc; secrets are added at deploy
// time via `wrangler secret put` so they aren't in source.

export interface Env {
  // ── Bindings declared in wrangler.jsonc ────────────────────────
  UPLOADS: R2Bucket;
  MEMORY: KVNamespace;

  // ── Vars (per env in wrangler.jsonc) ───────────────────────────
  ENVIRONMENT: 'dev' | 'staging' | 'production';
  SUPABASE_URL: string;
  ALLOWED_ORIGIN: string;

  // ── Secrets (set via `wrangler secret put --env <env>`) ────────
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  OPENROUTER_API_KEY: string;
  HONCHO_API_KEY: string;
  HONCHO_WORKSPACE_ID: string;
  // Web tools: Brave for search, Firecrawl for scrape — used by both the
  // in-chat search/read tools and the 奏折 runner.
  BRAVE_API_KEY: string;
  FIRECRAWL_API_KEY: string;
  // APNS: token-based auth, two .p8 keys (Apple recommends per-environment).
  // Topic = the iOS app bundle id (key is restricted to it).
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
  APNS_KEY_ID_DEV: string;
  APNS_KEY_ID_PROD: string;
  APNS_KEY_DEV: string;        // .p8 PEM content (secret)
  APNS_KEY_PROD: string;       // .p8 PEM content (secret)

  // Daytona — code-execution sandbox provider. API_URL / TOOLBOX_URL fall
  // back to the public hosts inside lib/sandbox.ts when unset; only the
  // API_KEY is required.
  DAYTONA_API_KEY: string;
  DAYTONA_API_URL?: string;
  DAYTONA_TOOLBOX_URL?: string;
}

// Hono's c.var slot — populated by middleware (auth, version, etc.)
export interface HonoVars {
  userId?: string;
  userJwt?: string;
  isAdmin?: boolean;
  clientVersion?: ClientVersion;
  clientPlatform?: 'ios' | 'web' | 'unknown';
}

export interface ClientVersion {
  raw: string;
  platform: string;
  major: number;
  minor: number;
  patch: number;
  gte(other: string): boolean;
}

export type AppBindings = {
  Bindings: Env;
  Variables: HonoVars;
};
