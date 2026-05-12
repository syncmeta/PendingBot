// Shape of the Cloudflare Worker bindings + secrets that every request handler
// receives via `c.env`. Mirrors wrangler.jsonc; secrets are added at deploy
// time via `wrangler secret put` so they aren't in source.

export interface Env {
  // ── Bindings declared in wrangler.jsonc ────────────────────────
  UPLOADS: R2Bucket;
  MEMORY: KVNamespace;
  /// Per-group debounce + small-model routing DO (M4 of group chat).
  /// One instance per conversation_id; routes via env.GROUP_ROUTER.get(
  /// env.GROUP_ROUTER.idFromName(conversationId)). See
  /// src/durable-objects/group-router.ts.
  GROUP_ROUTER: DurableObjectNamespace;
  /// Cloudflare ratelimit binding for handle-enumeration endpoints
  /// (friend-request /lookup, group /join, friend-request POST /).
  /// Limit + period live in wrangler.jsonc — call from a route via
  /// `withRateLimit(env.HANDLE_LOOKUP_RL, key)` in lib/rate-limit.ts.
  HANDLE_LOOKUP_RL: RateLimit;

  // ── Vars (per env in wrangler.jsonc) ───────────────────────────
  ENVIRONMENT: 'dev' | 'production';
  SUPABASE_URL: string;
  ALLOWED_ORIGIN: string;

  // ── Secrets (set via `wrangler secret put --env <env>`) ────────
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  OPENROUTER_API_KEY: string;
  // Optional alternative LLM gateway. The router resolves a provider's
  // env var name dynamically via llm_providers.secret_ref, so the key
  // doesn't need to be present at typecheck time — declaring it here
  // gives editor autocomplete and catches typos in admin UI input.
  WORLDROUTER_API_KEY?: string;
  HONCHO_API_KEY: string;
  HONCHO_WORKSPACE_ID: string;
  // Web tools — Brave/Firecrawl are the always-available pair (used by
  // in-chat search/read). The optional providers below let the Envelope
  // (来信) runner pick a different combo per-conversation; the runner
  // surfaces a clean error if a chosen provider's key is missing.
  BRAVE_API_KEY: string;
  FIRECRAWL_API_KEY: string;
  TAVILY_API_KEY?: string;
  EXA_API_KEY?: string;
  SERPER_API_KEY?: string;
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

  // ── Voice call (M5+) ───────────────────────────────────────────
  // OpenAI Realtime — the worker mints a 60s ephemeral client_secret
  // for the iOS WebRTC handshake; the API key never leaves the
  // worker. Also referenced by llm_providers row slug 'openai' via
  // secret_ref.
  OPENAI_API_KEY?: string;
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
