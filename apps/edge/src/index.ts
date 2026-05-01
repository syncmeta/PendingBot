import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import type { AppBindings } from './types';
import { healthRoutes } from './routes/health';
import { messageRoutes } from './routes/messages';
import { uploadRoutes } from './routes/upload';

// Top-level Hono app. Routes mount under /v1/ to leave room for a future v2
// (URL path = major-era versioning). Within v1, schema-driven compatibility
// via X-Client-Version header (see plans/.../07-deploy-test.md).

const app = new Hono<AppBindings>();

app.use('*', logger());

// CORS — lock to the configured origin per env. Worker exposes Authorization
// header for the supabase JWT carried on writes.
app.use('*', async (c, next) => {
  const origin = c.env.ALLOWED_ORIGIN;
  return cors({
    origin: origin ? [origin] : '*',
    credentials: true,
    allowHeaders: ['Authorization', 'Content-Type', 'X-Client-Version', 'X-Client-Platform'],
    maxAge: 600,
  })(c, next);
});

app.notFound((c) => c.json({ error: 'not found', path: c.req.path }, 404));

app.onError((err, c) => {
  console.error('[edge] unhandled', err);
  return c.json(
    {
      error: 'internal',
      message: c.env.ENVIRONMENT === 'production' ? undefined : String(err),
    },
    500,
  );
});

// Routes — mounted under /v1/
const v1 = new Hono<AppBindings>();
v1.route('/health', healthRoutes);
v1.route('/messages', messageRoutes);
v1.route('/upload', uploadRoutes);
v1.route('/uploads', uploadRoutes);   // GET /v1/uploads/:id

app.route('/v1', v1);

// Convenience: bare /health returns same payload (e.g. for uptime monitors
// that won't follow path conventions).
app.route('/health', healthRoutes);

export default app;
