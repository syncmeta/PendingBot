// apps/edge/src/routes/board-feature-flags.ts
//
// Feature-flags board endpoint (a single KV blob, not a table row, so it does
// NOT go through boardResource).
//   GET  /v1/board/feature-flags  → per-flag {override, envDefault, effective}
//   PUT  /v1/board/feature-flags  → write cfg:feature-flags overrides + admin_audit
// Sentry is read-only (envDefault/effective); it does not accept PUT changes
// (the error-reporter kill-switch must stay zero-runtime-dependency — see
// lib/feature-flags.ts header). Mounted under boardRoutes, so it inherits the
// Cloudflare Access gate (requireCfAccess + requireBoardAdmin).
import { Hono } from 'hono';
import { z } from 'zod';
import { jsonError } from '../lib/http-error';
import { recordBoardAudit } from '../lib/board-audit';
import { FLAGS_KV_KEY, type FlagOverrides } from '../lib/feature-flags';
import type { AppBindings, Env } from '../types';

export const boardFeatureFlagsRoutes = new Hono<AppBindings>();

async function readOverrides(env: Env): Promise<FlagOverrides> {
  try {
    return (await env.MEMORY.get<FlagOverrides>(FLAGS_KV_KEY, 'json')) ?? {};
  } catch {
    return {};
  }
}

function envDefault(v: string | undefined): boolean {
  return v === 'true';
}

boardFeatureFlagsRoutes.get('/', async (c) => {
  const ov = await readOverrides(c.env);
  const row = (name: 'billing' | 'posthog' | 'langfuse', env: string | undefined) => {
    const d = envDefault(env);
    const override = typeof ov[name] === 'boolean' ? (ov[name] as boolean) : null;
    return { override, envDefault: d, effective: override ?? d };
  };
  return c.json({
    data: {
      billing: row('billing', c.env.BILLING_ENABLED),
      posthog: row('posthog', c.env.POSTHOG_ENABLED),
      langfuse: row('langfuse', c.env.LANGFUSE_ENABLED),
      // Sentry read-only: no override concept; changing it requires a redeploy.
      sentry: {
        override: null,
        envDefault: envDefault(c.env.SENTRY_ENABLED),
        effective: envDefault(c.env.SENTRY_ENABLED),
        readonly: true,
      },
    },
  });
});

// PUT body: each key may be boolean (set an override) or null (clear it →
// fall back to env). Omitted = leave unchanged.
const PutBody = z.object({
  billing: z.boolean().nullable().optional(),
  posthog: z.boolean().nullable().optional(),
  langfuse: z.boolean().nullable().optional(),
});

boardFeatureFlagsRoutes.put('/', async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = PutBody.safeParse(body);
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });

  const before = await readOverrides(c.env);
  const next: FlagOverrides = { ...before };
  for (const k of ['billing', 'posthog', 'langfuse'] as const) {
    const v = parsed.data[k];
    if (v === undefined) continue; // omitted = unchanged
    if (v === null) delete next[k]; // null = clear override
    else next[k] = v; // boolean = set override
  }
  try {
    await c.env.MEMORY.put(FLAGS_KV_KEY, JSON.stringify(next));
  } catch (err) {
    return jsonError(c, 500, 'database_error', { detail: String(err) });
  }
  await recordBoardAudit(c, {
    action: 'update',
    targetKind: 'feature_flags',
    targetId: FLAGS_KV_KEY,
    before,
    after: next,
  });
  return c.json({ data: next });
});
