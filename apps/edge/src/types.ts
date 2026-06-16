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
  // Prompt library distribution cache. Langfuse is the source of truth for
  // prompts; they reach the worker via this KV (webhook-pushed on change +
  // pull-on-miss). See llm/prompt-loader.ts. May be undefined under bare
  // `wrangler dev` (default env declares no binding) — the loader degrades
  // to direct Langfuse pulls then.
  PROMPTS_KV: KVNamespace;
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
  /// conversation_id). Coordinates RealtimeKit participants, bot
  /// lifecycle, billing and diagnostics. See src/durable-objects/room-voice.ts.
  ROOM_VOICE: DurableObjectNamespace;
  /// Container-backed media engine for group voice — one instance per
  /// room (keyed by conversation_id via getContainer(env.ROOM_MEDIA, id)).
  /// RoomVoiceDO delegates the real-time audio path (RTK browser client,
  /// mix, OpenAI socket, bot-voice playout) to it so the work runs in a
  /// real OS process with reliable timers instead of a workerd isolate.
  /// See src/durable-objects/room-media.ts + apps/voice-container.
  ROOM_MEDIA: DurableObjectNamespace<RoomMediaContainerDO>;
  /// Cross-device session proxy DO (T4.5 — spec v2 §8.2 + §9.6). One
  /// instance per active crew session (keyed by session_id via
  /// SESSION_PROXY_DO.idFromName(sessionId)). It is the edge hub that lets
  /// any logged-in client on the same account watch + remote-control a
  /// session whose agent runs on a different machine (PendingCrew Mac now,
  /// Fly machine in v1.1 — same location-agnostic channel). Holds viewer
  /// sockets + at most one runner socket, routes commands / state /
  /// permission requests between them, and queues commands while the runner
  /// is offline. See src/durable-objects/session-proxy.ts.
  SESSION_PROXY_DO: DurableObjectNamespace;
  /// Per-subject 钱包缓存 DO(计费 P2)。一个实例每 subject(idFromName(subjectId))。
  /// Polar 是余额事实源;WalletDO 是边缘强一致缓存 + 门禁闸 + 用量 outbox。
  /// 见 docs/superpowers/specs/2026-06-02-billing-p2-architecture-fork.md。
  WALLET: DurableObjectNamespace;
  /// T2 边缘读投影 DO(消息尾,per-conversation)。一个实例每
  /// conversation_id(idFromName(conversationId))。SQLite-backed:存最近
  /// N_keep 条消息尾 + roster(授权门)+ 单调 revision(delta-sync cursor)。
  /// Supabase 仍是真源 / 事件源 / 重建源。webhook 写穿 + 冷启动回填。
  /// 见 src/durable-objects/conv-projection.ts +
  /// docs/superpowers/plans/2026-06-07-edge-read-offload.md。
  CONV_PROJECTION: DurableObjectNamespace;
  /// T2 边缘读投影 DO(会话列表 + 未读,per-user)。一个实例每 user_id
  /// (idFromName(userId))。SQLite-backed:存会话列表行 + 未读 + 单调
  /// revision(delta-sync cursor)。webhook 写穿 + 冷启动回填。
  /// 见 src/durable-objects/user-projection.ts。
  USER_PROJECTION: DurableObjectNamespace;
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
  /// Kill-switches (lib/feature-flags.ts). Plain vars, default OFF: only the
  /// exact string 'true' enables. BILLING_ENABLED gates the live billing
  /// gate + debit. Observability is PER-SERVICE so each vendor's quota can be
  /// controlled independently (each ALSO needs its own key/DSN to emit).
  BILLING_ENABLED?: string;
  SENTRY_ENABLED?: string;
  POSTHOG_ENABLED?: string;
  LANGFUSE_ENABLED?: string;
  SUPABASE_URL: string;
  ALLOWED_ORIGIN: string;
  /// Cloudflare Access coordinates for the board console gate
  /// (lib/cf-access.ts). Team domain like `<team>.cloudflareaccess.com` and
  /// the Access application AUD tag. The /v1/board/* gate is FAIL-CLOSED:
  /// unset vars reject every board request, so only set them together with a
  /// live Access app in front of the route.
  CF_ACCESS_TEAM_DOMAIN?: string;
  CF_ACCESS_AUD?: string;
  /// Board-admin allowlist (comma-separated emails). The Access-verified email
  /// must be in this list — a second, origin-side authority independent of the
  /// Access policy. FAIL-CLOSED: empty/unset denies all board access.
  BOARD_ADMIN_EMAILS?: string;
  /// Workers static assets (apps/admin SPA served under /board). Optional so
  /// test harnesses without the binding still typecheck; the /board route
  /// 404s when absent.
  ASSETS?: Fetcher;
  /// AI Gateway coordinates for the Logs API cost lookup (lib/ai-gateway.ts).
  /// Optional so `wrangler dev` without these set still typechecks/runs.
  CF_ACCOUNT_ID?: string;
  CF_AIG_GATEWAY?: string;
  /// BYOK key alias for the google-ai-studio provider. Gemini 3.x isn't
  /// served by AI Gateway Unified Billing on the native generateContent
  /// passthrough (only ~2.x is), so Google rides a stored BYOK key
  /// instead. The key is saved in the gateway dashboard under this alias;
  /// the gemini adapter sends it as the `cf-aig-byok-alias` header so the
  /// gateway injects this key (a non-`default` alias must be named
  /// explicitly). Unset → no alias header (relies on a `default` key /
  /// Unified Billing). Not a secret — just the alias name.
  GOOGLE_BYOK_ALIAS?: string;

  /// Publishable API key (`sb_publishable_…`). Public by design — plain var
  /// in wrangler.jsonc, not a secret. userClient pairs it with the caller's
  /// JWT so RLS runs as `authenticated`.
  SUPABASE_PUBLISHABLE_KEY: string;

  // ── Secrets (set via `wrangler secret put --env <env>`) ────────
  /// Secret API key (`sb_secret_…`). Maps to the `service_role` Postgres
  /// role (BYPASSRLS) — same privileges as the legacy service_role JWT,
  /// but independently rotatable/revocable.
  SUPABASE_SECRET_KEY: string;
  /// Cloudflare API token (AI Gateway Read). persistAuditMessage uses it
  /// to read the gateway's computed per-request cost from the Logs API
  /// when a provider doesn't report its own. Optional — unset means
  /// those turns record no LLM cost.
  CF_AIG_TOKEN?: string;
  /// AI Gateway "Authenticated Gateway" run token (created in the gateway
  /// Settings with Run permission). buildClient sends it as the
  /// cf-aig-authorization header on every LLM request; the gateway then
  /// pays the upstream from the account's Unified Billing credits (the
  /// google-ai-studio path is the exception — it adds cf-aig-byok-alias
  /// to use a stored BYOK key, see GOOGLE_BYOK_ALIAS).
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

  // ── Group voice (CF RealtimeKit) ───────────────────────────────
  // RealtimeKit app id for the group call room/participant-token path.
  // The API token is secret; account id falls back to CF_ACCOUNT_ID.
  REALTIMEKIT_ACCOUNT_ID?: string;
  REALTIMEKIT_APP_ID?: string;
  REALTIMEKIT_API_TOKEN?: string;
  // Preset names are configured in the RealtimeKit dashboard. Defaults in
  // routes/group-voice.ts match Cloudflare's starter group-call presets.
  REALTIMEKIT_HUMAN_PRESET?: string;
  REALTIMEKIT_BOT_PRESET?: string;

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

  // ── Polar (MoR + 预付钱包 + usage，见 docs/superpowers/specs/2026-06-01-billing-engine-design.md) ──
  // web/Mac 收款+代税 + credit 钱包 + 用量计量的事实源。SDK: @polar-sh/sdk。
  // 本地写 .dev.vars；生产 `wrangler secret put POLAR_ACCESS_TOKEN`。
  POLAR_ACCESS_TOKEN?: string;
  POLAR_SERVER?: string; // 'sandbox' | 'production'
  POLAR_WEBHOOK_SECRET?: string; // Polar webhook signing secret(Standard Webhooks)
  POLAR_PNC_METER_ID?: string; // bootstrap 建的 pnc meter id
  REVENUECAT_WEBHOOK_AUTH?: string; // RevenueCat webhook Authorization 头共享密钥

  // ── Observability (dashboard stack) ────────────────────────────
  // All env-gated: a feature is fully no-op when its key(s) are unset,
  // so dev / preview deploys without these configured behave exactly as
  // before. See docs/superpowers/specs/2026-06-01-dashboard-stack-design.md.
  //
  // Sentry error tracking. DSN unset → withSentry's options callback
  // returns undefined → the SDK is not initialized (index.ts).
  SENTRY_DSN?: string;
  // PostHog product analytics. KEY unset → lib/analytics.ts capture() is a
  // no-op. HOST defaults to PostHog cloud when unset (set for self-hosted /
  // EU region). See lib/analytics.ts.
  POSTHOG_KEY?: string;
  POSTHOG_HOST?: string;
  // Langfuse LLM observability. Both keys must be set for lib/llm-trace.ts
  // to emit; either unset → no-op. BASE_URL defaults to Langfuse cloud.
  LANGFUSE_PUBLIC_KEY?: string;
  LANGFUSE_SECRET_KEY?: string;
  LANGFUSE_BASE_URL?: string;
  // Shared secret for Langfuse prompt-version webhooks. Requests carry an
  // HMAC-SHA256 signature over `${timestamp}.${rawBody}` in x-langfuse-signature.
  // Set this both in the Langfuse webhook config and as a worker secret.
  // Unset → the webhook endpoint returns 501. See routes/langfuse-prompts.ts.
  LANGFUSE_WEBHOOK_SECRET?: string;
}

// Hono's c.var slot — populated by middleware (auth, version, etc.)
export interface HonoVars {
  userId?: string;
  userJwt?: string;
  authKind?: 'supabase_jwt' | 'device_grant';
  deviceGrant?: {
    id: string;
    subjectId: string;
    grantedByUserId: string | null;
    grantKind: string;
    scopes: string[];
    appKind: string;
  };
  /// Cloudflare Access-authenticated email for the board console
  /// (set by requireCfAccess). Board authz/audit key off this, not userId.
  boardEmail?: string;
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
