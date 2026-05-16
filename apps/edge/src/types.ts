// Shape of the Cloudflare Worker bindings + secrets that every request handler
// receives via `c.env`. Mirrors wrangler.jsonc; secrets are added at deploy
// time via `wrangler secret put` so they aren't in source.

import type { Sandbox } from '@cloudflare/sandbox';
import type { AuditMessage } from './queue/audit-types';

export interface Env {
  // ── Bindings declared in wrangler.jsonc ────────────────────────
  UPLOADS: R2Bucket;
  MEMORY: KVNamespace;
  /// Per-group debounce + small-model routing DO (M4 of group chat).
  /// One instance per conversation_id; routes via env.GROUP_ROUTER.get(
  /// env.GROUP_ROUTER.idFromName(conversationId)). See
  /// src/durable-objects/group-router.ts.
  GROUP_ROUTER: DurableObjectNamespace;
  /// Cloudflare Sandbox SDK — container-backed DO used by the chat
  /// agent's execute_code tool. Keyed by conversation_id via
  /// `getSandbox(env.Sandbox, conversationId)`; auto-sleeps after
  /// inactivity (no manual cleanup needed). See lib/sandbox.ts.
  Sandbox: DurableObjectNamespace<Sandbox>;
  /// Per-conversation realtime fan-out DO. One instance per
  /// conversation_id; holds the live WebSocket connections of every
  /// client viewing that conversation. Reached via
  /// env.CONV_HUB.get(env.CONV_HUB.idFromName(conversationId)). See
  /// src/durable-objects/conv-hub.ts.
  CONV_HUB: DurableObjectNamespace;
  /// Cloudflare ratelimit binding for handle-enumeration endpoints
  /// (friend-request /lookup, group /join, friend-request POST /).
  /// Limit + period live in wrangler.jsonc — call from a route via
  /// `withRateLimit(env.HANDLE_LOOKUP_RL, key)` in lib/rate-limit.ts.
  HANDLE_LOOKUP_RL: RateLimit;
  /// Audit + billing offload queue. enqueueAudit (src/llm/router.ts)
  /// is the only producer; the worker's own `queue` handler in
  /// src/index.ts is the consumer. See wrangler.jsonc → queues.
  AUDIT_QUEUE: Queue<AuditMessage>;

  // ── Vars (per env in wrangler.jsonc) ───────────────────────────
  ENVIRONMENT: 'dev' | 'production';
  SUPABASE_URL: string;
  ALLOWED_ORIGIN: string;
  /// AI Gateway coordinates for the Logs API cost lookup (lib/ai-gateway.ts).
  /// Optional so `wrangler dev` without these set still typechecks/runs.
  CF_ACCOUNT_ID?: string;
  CF_AIG_GATEWAY?: string;

  // ── Secrets (set via `wrangler secret put --env <env>`) ────────
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  OPENROUTER_API_KEY: string;
  // Optional alternative LLM gateway. The router resolves a provider's
  // env var name dynamically via llm_providers.secret_ref, so the key
  // doesn't need to be present at typecheck time — declaring it here
  // gives editor autocomplete and catches typos in admin UI input.
  WORLDROUTER_API_KEY?: string;
  /// Cloudflare API token (AI Gateway Read). persistAuditMessage uses it
  /// to read the gateway's computed per-request cost from the Logs API
  /// when a provider doesn't report its own. Optional — unset means
  /// those turns record no LLM cost.
  CF_AIG_TOKEN?: string;
  HONCHO_API_KEY: string;
  HONCHO_WORKSPACE_ID: string;
  // Web tools route through the MCP client (apps/edge/src/mcp/client.ts)
  // to Exa's hosted MCP at mcp.exa.ai. TAVILY_API_KEY stays declared
  // because the upcoming skill mechanism will plumb Tavily through a
  // subscribable skill — not exposed by default on the chat surface.
  EXA_API_KEY?: string;
  TAVILY_API_KEY?: string;
  // APNS: token-based auth, two .p8 keys (Apple recommends per-environment).
  // Topic = the iOS app bundle id (key is restricted to it).
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
  APNS_KEY_ID_DEV: string;
  APNS_KEY_ID_PROD: string;
  APNS_KEY_DEV: string;        // .p8 PEM content (secret)
  APNS_KEY_PROD: string;       // .p8 PEM content (secret)

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
