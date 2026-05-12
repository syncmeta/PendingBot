import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import type { AppBindings, Env } from './types';
import { jsonError } from './lib/http-error';
import { healthRoutes } from './routes/health';
import { messageRoutes } from './routes/messages';
import { conversationRoutes } from './routes/conversations';
import { botRoutes } from './routes/bots';
import { uploadRoutes } from './routes/upload';
import { scrollRoutes } from './routes/scroll';
import { meRoutes } from './routes/me';
import { contactRoutes } from './routes/contacts';
import { friendRequestRoutes } from './routes/friend-requests';
import { groupRoutes } from './routes/groups';
import { deviceRoutes } from './routes/devices';
import { codeExecRoutes } from './routes/code-exec';
import { openrouterRoutes } from './routes/openrouter';
import { realtimeRoutes } from './routes/realtime';
import { wellKnownRoutes } from './routes/well-known';
import { handleScheduled } from './cron';

// Re-export the Durable Object class so the runtime can find it via
// the `class_name` field in wrangler.jsonc → durable_objects.bindings.
// The export *name* must match `class_name` (case-sensitive).
export { GroupRouterDO } from './durable-objects/group-router';

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
v1.route('/conversations', conversationRoutes);
v1.route('/bots', botRoutes);
v1.route('/upload', uploadRoutes);
v1.route('/uploads', uploadRoutes);   // GET /v1/uploads/:id
v1.route('/scroll', scrollRoutes);
v1.route('/me', meRoutes);
v1.route('/contacts', contactRoutes);
v1.route('/friend-requests', friendRequestRoutes);
v1.route('/groups', groupRoutes);
v1.route('/devices', deviceRoutes);
v1.route('/code-exec-requests', codeExecRoutes);
v1.route('/openrouter', openrouterRoutes);
v1.route('/realtime', realtimeRoutes);

app.route('/v1', v1);

// Convenience: bare /health returns same payload (e.g. for uptime monitors
// that won't follow path conventions).
app.route('/health', healthRoutes);

// Apple Universal Links — AASA at bot.pendingname.com/.well-known/...
// Bound via a worker route in wrangler.jsonc; lives outside /v1/ since
// Apple fetches the well-known path verbatim.
app.route('/.well-known', wellKnownRoutes);

// Workers entry point: HTTP via Hono, scheduled (cron) via handleScheduled.
// Hono's default export is `{ fetch }`, so we wrap it to add the scheduled
// hook. wrangler.jsonc declares triggers.crons; controller.cron tells us
// which schedule fired.
export default {
  fetch: app.fetch,
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    await handleScheduled(controller, env, ctx);
  },
};
