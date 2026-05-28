import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import type { AppBindings, Env } from './types';
import { jsonError } from './lib/http-error';
import { healthRoutes } from './routes/health';
import { messageRoutes } from './routes/messages';
import { botRoutes } from './routes/bots';
import { uploadRoutes } from './routes/upload';
import { envelopeRoutes } from './routes/envelope';
import { meRoutes } from './routes/me';
import { contactRoutes } from './routes/contacts';
import { friendRequestRoutes } from './routes/friend-requests';
import { groupRoutes } from './routes/groups';
import { crewRoutes } from './routes/crew';
import { crewsRoutes } from './routes/crews';
import { crewMessagesRoutes, sessionInboxRoutes } from './routes/crew-comms';
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
import { runnerHostRoutes } from './routes/runner-hosts';
import { humanHelpRequestRoutes } from './routes/human-help-requests';
import { codeExecRoutes } from './routes/code-exec';
import { modelCatalogRoutes } from './routes/models';
import { arenaRoutes } from './routes/arena';
import { realtimeRoutes } from './routes/realtime';
import { realtimeHubRoutes } from './routes/realtime-hub';
import { realtimeInternalRoutes } from './routes/realtime-internal';
import { wellKnownRoutes } from './routes/well-known';
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
// Container-backed DO from @cloudflare/sandbox. Required export for
// the `Sandbox` binding declared in wrangler.jsonc.
export { Sandbox } from '@cloudflare/sandbox';

// Top-level Hono app. Routes mount under /v1/ to leave room for a future v2
// (URL path = major-era versioning). Within v1, schema-driven compatibility
// via X-Client-Version header (see plans/.../07-deploy-test.md).

const app = new Hono<AppBindings>();

app.use('*', logger());

// CORS — lock to the configured origin per env. Worker exposes Authorization
// header for the supabase JWT carried on writes.
//
// Fallback when ALLOWED_ORIGIN is unset: deny all browser origins (return []).
// Native iOS clients don't honor CORS so they're unaffected — only browsers
// hit this code path, and we want a hostile site to be unable to mount
// credentialed requests against a misconfigured deploy. Production must set
// ALLOWED_ORIGIN explicitly.
app.use('*', async (c, next) => {
  const origin = c.env.ALLOWED_ORIGIN;
  return cors({
    origin: origin ? [origin] : [],
    credentials: true,
    allowHeaders: ['Authorization', 'Content-Type', 'X-Client-Version', 'X-Client-Platform'],
    maxAge: 600,
  })(c, next);
});

app.notFound((c) => jsonError(c, 404, 'not_found', { detail: { path: c.req.path } }));

app.onError((err, c) => {
  console.error('[edge] unhandled', err);
  return jsonError(c, 500, 'internal_error', {
    message: c.env.ENVIRONMENT === 'production' ? undefined : String(err),
  });
});

// Routes — mounted under /v1/
const v1 = new Hono<AppBindings>();
v1.route('/health', healthRoutes);
v1.route('/messages', messageRoutes);
v1.route('/bots', botRoutes);
v1.route('/upload', uploadRoutes);
v1.route('/uploads', uploadRoutes);   // GET /v1/uploads/:id
v1.route('/envelope', envelopeRoutes);
v1.route('/me', meRoutes);
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
v1.route('/share-changes', shareChangesRoutes);
v1.route('/groups', groupVoiceRoutes);
v1.route('/voice', voiceActiveRoutes);
v1.route('/devices', deviceRoutes);
v1.route('/device-login', deviceLoginRoutes);
v1.route('/runner-hosts', runnerHostRoutes);
v1.route('/human-help-requests', humanHelpRequestRoutes);
v1.route('/code-exec-requests', codeExecRoutes);
v1.route('/models', modelCatalogRoutes);
v1.route('/arena', arenaRoutes);
v1.route('/realtime', realtimeRoutes);
v1.route('/realtime-hub', realtimeHubRoutes);
v1.route('/realtime-internal', realtimeInternalRoutes);

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
export default {
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
          msg.retry();
        }
      }
    }
  },
};
