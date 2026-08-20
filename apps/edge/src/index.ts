import * as Sentry from '@sentry/cloudflare';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import type { AppBindings, Env } from './types';
import { jsonError } from './lib/http-error';
import { sentryEnabled } from './lib/feature-flags';
import { healthRoutes } from './routes/health';
import { messageRoutes } from './routes/messages';
import { botRoutes } from './routes/bots';
import { botInviteRoutes } from './routes/bot-invites';
import { groupInviteLinkRoutes, groupInviteTokenRoutes } from './routes/group-invites';
import { uploadRoutes } from './routes/upload';
import { envelopeRoutes } from './routes/envelope';
import { meRoutes } from './routes/me';
import { groupSubjectRoutes } from './routes/group-subjects';
import { contactRoutes } from './routes/contacts';
import { friendRequestRoutes } from './routes/friend-requests';
import { groupRoutes } from './routes/groups';
import { crewRoutes } from './routes/crew';
import { crewsRoutes } from './routes/crews';
import { machinesRoutes } from './routes/machines';
import { crewMessagesRoutes, sessionInboxRoutes } from './routes/crew-comms';
import { sessionProxyRoutes } from './routes/session-proxy';
import { crewInteractionRoutes, crewInteractionAnswerRoutes } from './routes/crew-interactions';
import {
  permissionRequestRoutes,
  crewPermissionModeRoutes,
  sessionPermissionModeRoutes,
} from './routes/permission-requests';
import { shareChangesRoutes } from './routes/share-changes';
import { groupVoiceRoutes } from './routes/group-voice';
import { voiceActiveRoutes } from './routes/voice-active';
import { deviceRoutes } from './routes/devices';
import { deviceLoginRoutes } from './routes/device-login';
import { deviceGrantRoutes } from './routes/device-grant';
import { runnerHostRoutes } from './routes/runner-hosts';
import { humanHelpRequestRoutes } from './routes/human-help-requests';
import { codeExecRoutes } from './routes/code-exec';
import { modelCatalogRoutes } from './routes/models';
import { modelPresetsRoutes } from './routes/model-presets';
import { realtimeRoutes } from './routes/realtime';
import { realtimeHubRoutes } from './routes/realtime-hub';
import { realtimeInternalRoutes } from './routes/realtime-internal';
import { conversationListRoutes, messageTailRoutes } from './routes/projections';
import { conversationModelRoutes } from './routes/conversation-model-routes';
import { wellKnownRoutes } from './routes/well-known';
import { billingWebhookRoutes } from './routes/billing-webhooks';
import { langfusePromptRoutes } from './routes/langfuse-prompts';
import { boardRoutes } from './routes/board';
import { handleScheduled } from './cron';
import { persistAuditMessage, GatewayCostPendingError } from './llm/router';
import type { AuditMessage } from './queue/audit-types';

// Re-export the Durable Object class so the runtime can find it via
// the `class_name` field in wrangler.jsonc → durable_objects.bindings.
// The export *name* must match `class_name` (case-sensitive).
export { GroupRouterDO } from './durable-objects/group-router';
export { RealtimeHubDO } from './durable-objects/hub';
export { RealtimeMeterDO } from './durable-objects/realtime-meter';
export { RoomVoiceDO } from './durable-objects/room-voice';
// Container-enabled DO wrapping the group-voice media container
// (apps/voice-container). Required export for the ROOM_MEDIA binding.
export { RoomMediaContainerDO } from './durable-objects/room-media';
// Cross-device session remote-control DO (T4.5). Required export for the
// SESSION_PROXY_DO binding declared in wrangler.jsonc.
export { SessionProxyDO } from './durable-objects/session-proxy';
// Per-subject 钱包缓存 DO(计费 P2)。WALLET binding 的必需导出。
export { WalletDO } from './durable-objects/wallet';
// T2 边缘读投影 DO。CONV_PROJECTION / USER_PROJECTION binding 的必需导出。
export { ConvProjectionDO } from './durable-objects/conv-projection';
export { UserProjectionDO } from './durable-objects/user-projection';
// Container-backed DO from @cloudflare/sandbox. Required export for
// the `Sandbox` binding declared in wrangler.jsonc.
export { Sandbox } from '@cloudflare/sandbox';

// Top-level Hono app. Routes mount under /v1/ to leave room for a future v2
// (URL path = major-era versioning). Within v1, schema-driven compatibility
// via X-Client-Version header (see plans/.../07-deploy-test.md).

const app = new Hono<AppBindings>();

app.use('*', logger());

// CORS — lock to the configured origin(s) per env. Worker exposes
// Authorization header for the supabase JWT carried on writes.
// ALLOWED_ORIGIN is comma-separated (app origin + admin console origin).
//
// Fallback when ALLOWED_ORIGIN is unset: deny all browser origins (return []).
// Native iOS clients don't honor CORS so they're unaffected — only browsers
// hit this code path, and we want a hostile site to be unable to mount
// credentialed requests against a misconfigured deploy. Production must set
// ALLOWED_ORIGIN explicitly.
app.use('*', async (c, next) => {
  const origin = c.env.ALLOWED_ORIGIN;
  return cors({
    origin: origin
      ? origin
          .split(',')
          .map((o) => o.trim())
          .filter(Boolean)
      : [],
    credentials: true,
    allowHeaders: ['Authorization', 'Content-Type', 'X-Client-Version', 'X-Client-Platform'],
    maxAge: 600,
  })(c, next);
});

app.notFound((c) => jsonError(c, 404, 'not_found', { detail: { path: c.req.path } }));

app.onError((err, c) => {
  console.error('[edge] unhandled', err);
  // Hono's onError turns the throw into a 500 *response*, so it never
  // propagates out of app.fetch — which means withSentry's handler
  // instrumentation would never see it. Capture explicitly here, with the
  // request path/method as context, so unhandled 500s actually reach Sentry.
  // No-op when SENTRY_DSN is unset (the SDK isn't initialized).
  Sentry.captureException(err, {
    extra: { method: c.req.method, path: c.req.path },
  });
  return jsonError(c, 500, 'internal_error', {
    message: c.env.ENVIRONMENT === 'production' ? undefined : String(err),
  });
});

// Board admin console — apps/admin SPA served same-origin from the assets
// binding so the Cloudflare Access cookie covers both the page and the
// /v1/board/* API (a cross-origin host couldn't carry it). The built SPA
// uses base /board/, the binding's directory is the bare dist/, so strip the
// prefix before asset lookup; unknown paths fall through to index.html
// (assets.not_found_handling = single-page-application).
app.get('/board', (c) => c.redirect('/board/'));
app.get('/board/*', (c) => {
  const assets = c.env.ASSETS;
  if (!assets) return jsonError(c, 404, 'not_found');
  const url = new URL(c.req.url);
  url.pathname = url.pathname.replace(/^\/board/, '') || '/';
  return assets.fetch(new Request(url.toString(), c.req.raw));
});

// Routes — mounted under /v1/
const v1 = new Hono<AppBindings>();
v1.route('/health', healthRoutes);
v1.route('/messages', messageRoutes);
v1.route('/messages', messageTailRoutes);          // GET /v1/messages/tail (T2 边缘读投影 — 消息尾)
v1.route('/conversations', conversationListRoutes); // GET /v1/conversations (T2 边缘读投影 — 会话列表+未读)
v1.route('/conversations', conversationModelRoutes); // GET /:id/model · POST /:id/reveal-model · POST /:id/model (盲盒)
v1.route('/bots', botRoutes);
v1.route('/bot-invites', botInviteRoutes);         // GET/:token resolve · POST/:token/redeem · DELETE/:token
v1.route('/groups', groupInviteLinkRoutes);        // POST/GET /v1/groups/:id/invite-links (D2)
v1.route('/group-invites', groupInviteTokenRoutes);// GET/:token resolve · POST/:token/redeem · DELETE/:token
v1.route('/upload', uploadRoutes);
v1.route('/uploads', uploadRoutes);   // GET /v1/uploads/:id
v1.route('/envelope', envelopeRoutes);
v1.route('/me', meRoutes);
v1.route('/group-subjects', groupSubjectRoutes);
v1.route('/contacts', contactRoutes);
v1.route('/friend-requests', friendRequestRoutes);
v1.route('/groups', groupRoutes);
v1.route('/crew', crewRoutes);
v1.route('/crews', crewsRoutes);
v1.route('/crews', crewMessagesRoutes);            // POST /v1/crews/:crewId/messages
v1.route('/sessions', sessionInboxRoutes);         // GET /v1/sessions/:sessionId/inbox + mark-delivered
v1.route('/permission-requests', permissionRequestRoutes);   // POST /v1/permission-requests/:id/decide
v1.route('/crews', crewPermissionModeRoutes);                // PATCH /v1/crews/:crewId/permission-mode
v1.route('/sessions', sessionPermissionModeRoutes);          // PATCH /v1/sessions/:sessionId/permission-mode
v1.route('/sessions', sessionProxyRoutes);                   // GET /v1/sessions/:sessionId/proxy/connect (ws upgrade)
v1.route('/sessions', crewInteractionRoutes);                // POST/GET /v1/sessions/:sessionId/interactions (T4.5 ask_human)
v1.route('/interactions', crewInteractionAnswerRoutes);      // POST /v1/interactions/:reqId/answer
v1.route('/share-changes', shareChangesRoutes);
v1.route('/machines', machinesRoutes);             // GET /v1/machines + POST /v1/machines/register-self
v1.route('/groups', groupVoiceRoutes);
v1.route('/voice', voiceActiveRoutes);
v1.route('/devices', deviceRoutes);
v1.route('/device-login', deviceLoginRoutes);
v1.route('/device-grant', deviceGrantRoutes);
v1.route('/runner-hosts', runnerHostRoutes);
v1.route('/human-help-requests', humanHelpRequestRoutes);
v1.route('/code-exec-requests', codeExecRoutes);
v1.route('/models', modelCatalogRoutes);
v1.route('/model-presets', modelPresetsRoutes);
v1.route('/realtime', realtimeRoutes);
v1.route('/realtime-hub', realtimeHubRoutes);
v1.route('/realtime-internal', realtimeInternalRoutes);
v1.route('/billing', billingWebhookRoutes);  // /v1/billing/polar/webhook + /v1/billing/revenuecat/webhook
v1.route('/langfuse', langfusePromptRoutes);  // /v1/langfuse/prompt-webhook (Langfuse prompt-version → PROMPTS_KV)
v1.route('/board', boardRoutes);  // 内容/预设/配置管理台(Cloudflare Access: requireCfAccess + requireBoardAdmin)

app.route('/v1', v1);

// Convenience: bare /health returns same payload (e.g. for uptime monitors
// that won't follow path conventions).
app.route('/health', healthRoutes);

// Apple Universal Links — AASA at bot.pendingname.com/.well-known/...
// Bound via a worker route in wrangler.jsonc; lives outside /v1/ since
// Apple fetches the well-known path verbatim.
app.route('/.well-known', wellKnownRoutes);

// Workers entry point: HTTP via Hono, scheduled (cron) via handleScheduled,
// and the AUDIT_QUEUE consumer via `queue`. Hono's default export is
// `{ fetch }`, so we wrap it to add the scheduled + queue hooks.
const handler = {
  fetch: app.fetch,
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    await handleScheduled(controller, env, ctx);
  },
  // AUDIT_QUEUE consumer. Each message is one LLM turn's audit + billing
  // work (see enqueueAudit / persistAuditMessage in src/llm/router.ts).
  // persistAuditMessage is idempotent on the message's auditId, so a
  // retried delivery is safe. ack on success; retry on a thrown error
  // (transient audit_log insert failure) — after wrangler.jsonc's
  // max_retries the message lands in pendingbot-audit-dlq.
  async queue(batch: MessageBatch<AuditMessage>, env: Env) {
    for (const msg of batch.messages) {
      try {
        await persistAuditMessage(env, msg.body);
        msg.ack();
      } catch (err) {
        if (err instanceof GatewayCostPendingError) {
          // The turn's AI Gateway cost log hasn't been ingested yet —
          // re-queue with a delay rather than spinning. After
          // wrangler.jsonc's max_retries the message lands in the DLQ.
          msg.retry({ delaySeconds: 60 });
        } else {
          console.error('[queue:audit] persist failed, will retry', err);
          // Real persistence failure (not the expected cost-pending race).
          // After max_retries this message lands in the DLQ, so surface it
          // to Sentry rather than only logging. No-op when DSN unset.
          Sentry.captureException(err, {
            tags: { source: 'queue:audit' },
            extra: { auditId: msg.body?.auditId },
          });
          msg.retry();
        }
      }
    }
  },
};

// Sentry error tracking — wraps the whole handler (fetch + scheduled +
// queue) so unhandled exceptions across every entry point are captured.
// Gated twice: SENTRY_ENABLED must be 'true' (per-service kill-switch, default
// OFF so dev / pre-launch doesn't flood Sentry's quota) AND SENTRY_DSN must be
// set. When either is off the options callback returns undefined, which tells
// withSentry to skip SDK initialization entirely — a true no-op, so every
// captureException() downstream is also dormant. See feature-flags.ts and
// docs/superpowers/specs/2026-06-01-dashboard-stack-design.md.
export default Sentry.withSentry<Env, AuditMessage>(
  (env: Env) =>
    sentryEnabled(env) && env.SENTRY_DSN
      ? {
          dsn: env.SENTRY_DSN,
          // Sample rate for performance tracing. Errors are always
          // captured; tracing is sampled to keep volume/cost sane. Tune
          // (or wire to an env var) once real traffic data exists.
          tracesSampleRate: 0.1,
          environment: env.ENVIRONMENT,
          // Don't send PII (IP, headers) by default — this is a privacy-
          // sensitive chat product. Opt specific context in deliberately.
          sendDefaultPii: false,
        }
      : undefined,
  handler,
);
