// Shape of the Cloudflare Worker bindings + secrets that every request handler
// receives via `c.env`. Mirrors wrangler.jsonc; secrets are added at deploy
// time via `wrangler secret put` so they aren't in source.

import type { Sandbox } from '@cloudflare/sandbox';
import type { RoomMediaContainerDO } from './durable-objects/room-media';
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
  /// Realtime fan-out DO. One instance per topic — `conv:<id>` for a
  /// conversation, `user:<id>` for a user's resident connection.
  /// Holds clients' hibernatable WebSocket connections and broadcasts
  /// row changes pushed in by the webhook-notify path. Reached via
  /// env.REALTIME_HUB.get(env.REALTIME_HUB.idFromName(key)). See
  /// src/durable-objects/hub.ts.
  REALTIME_HUB: DurableObjectNamespace;
  /// Per-voice-call server-side metering DO. One instance per realtime
  /// session_id. Holds a "sideband" WebSocket to OpenAI — a control
  /// connection to the same call the iOS WebRTC client is on — so token
  /// usage is metered server-side instead of self-reported by the
  /// client. See src/durable-objects/realtime-meter.ts.
  REALTIME_METER: DurableObjectNamespace;
  /// Group-voice bridge DO — one instance per group call (keyed by
  /// conversation_id). Bridges humans on the Cloudflare Realtime SFU to
  /// OpenAI Realtime via the SFU's WebSocket adapter: no WebRTC stack in
  /// the worker. See src/durable-objects/room-voice.ts.
  ROOM_VOICE: DurableObjectNamespace;
  /// Container-backed media engine for group voice — one instance per
  /// room (keyed by conversation_id via getContainer(env.ROOM_MEDIA, id)).
  /// RoomVoiceDO delegates the real-time audio path (SFU adapter PCM, mix,
  /// OpenAI socket, bot-voice playout) to it so the work runs in a real OS
  /// process with reliable timers instead of a workerd isolate. See
  /// src/durable-objects/room-media.ts + apps/voice-container.
  ROOM_MEDIA: DurableObjectNamespace<RoomMediaContainerDO>;
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
  /// Cloudflare API token (AI Gateway Read). persistAuditMessage uses it
  /// to read the gateway's computed per-request cost from the Logs API
  /// when a provider doesn't report its own. Optional — unset means
  /// those turns record no LLM cost.
  CF_AIG_TOKEN?: string;
  /// AI Gateway "Authenticated Gateway" run token (created in the gateway
  /// Settings with Run permission). buildClient sends it as the
  /// cf-aig-authorization header on every LLM request; the gateway then
  /// injects the BYOK provider key stored in its dashboard.
  CF_AIG_RUN_TOKEN?: string;
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
  // for the iOS WebRTC handshake; the API key never leaves the worker.
  OPENAI_API_KEY?: string;

  // ── Group voice (CF Realtime SFU) ──────────────────────────────
  // SFU app id — pairs with SFU_APP_SECRET to authenticate the SFU API
  // (sessions, tracks, WebSocket adapters). The id is not sensitive.
  SFU_APP_ID?: string;
  // SFU app secret — bearer token for rtc.live.cloudflare.com. Secret.
  SFU_APP_SECRET?: string;

  // ── TURN relay (webrtc_turn voice transport) ───────────────────
  // Cloudflare Realtime TURN key. The worker mints short-lived ICE
  // relay credentials (lib/cf-turn.ts) so the iOS WebRTC client can
  // route 1:1 voice media through Cloudflare's TURN servers — the
  // middle fallback between direct WebRTC and the WebSocket relay.
  // Both unset → 'webrtc_turn' sessions fail; auto mode skips to WS.
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;

  // ── Realtime fan-in ────────────────────────────────────────────
  // Shared secret the Supabase Database Webhooks send in the
  // X-Webhook-Secret header on every POST to /v1/realtime-internal/
  // notify. The notify route rejects any request that doesn't match.
  // Optional at typecheck time (a secret); must be set in prod and
  // mirrored into Supabase Vault as `realtime_webhook_secret`.
  REALTIME_WEBHOOK_SECRET?: string;
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
