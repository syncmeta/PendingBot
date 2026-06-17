// apps/edge/src/routes/board-model-roles.ts
//
// System model-role board endpoint (a single KV blob, mirrors board-feature-flags;
// does NOT go through boardResource).
//   GET  /v1/board/model-roles  → per-role {override, codeDefault, effective}
//   PUT  /v1/board/model-roles  → write cfg:model-roles overrides + admin_audit
// Mounted under boardRoutes, so it inherits the Cloudflare Access gate
// (requireCfAccess + requireBoardAdmin).
import { Hono } from 'hono';
import { z } from 'zod';
import { jsonError } from '../lib/http-error';
import { recordBoardAudit } from '../lib/board-audit';
import {
  MODEL_ROLES_KV_KEY,
  MODEL_ROLE_DEFAULTS,
  MODEL_ROLE_KEYS,
  type ModelRole,
  type RoleOverrides,
} from '../lib/model-roles';
import type { AppBindings, Env } from '../types';

export const boardModelRolesRoutes = new Hono<AppBindings>();

async function readOverrides(env: Env): Promise<RoleOverrides> {
  try {
    return (await env.MEMORY.get<RoleOverrides>(MODEL_ROLES_KV_KEY, 'json')) ?? {};
  } catch {
    return {};
  }
}

boardModelRolesRoutes.get('/', async (c) => {
  const ov = await readOverrides(c.env);
  const data: Record<ModelRole, { override: string | null; codeDefault: string; effective: string }> =
    {} as Record<ModelRole, { override: string | null; codeDefault: string; effective: string }>;
  for (const role of MODEL_ROLE_KEYS) {
    const raw = ov[role];
    const override = typeof raw === 'string' && raw.length > 0 ? raw : null;
    data[role] = {
      override,
      codeDefault: MODEL_ROLE_DEFAULTS[role],
      effective: override ?? MODEL_ROLE_DEFAULTS[role],
    };
  }
  return c.json({ data });
});

// PUT body: each role may be a non-empty slug string (set an override) or null
// (clear it → fall back to the code default). Omitted = leave unchanged.
const PutBody = z.record(
  z.enum(MODEL_ROLE_KEYS as [ModelRole, ...ModelRole[]]),
  z.string().min(1).nullable().optional(),
);

boardModelRolesRoutes.put('/', async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = PutBody.safeParse(body);
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });

  const before = await readOverrides(c.env);
  const next: RoleOverrides = { ...before };
  for (const role of MODEL_ROLE_KEYS) {
    const v = parsed.data[role];
    if (v === undefined) continue; // omitted = unchanged
    if (v === null) delete next[role]; // null = clear override
    else next[role] = v; // non-empty string = set override
  }
  try {
    await c.env.MEMORY.put(MODEL_ROLES_KV_KEY, JSON.stringify(next));
  } catch (err) {
    return jsonError(c, 500, 'database_error', { detail: String(err) });
  }
  await recordBoardAudit(c, {
    action: 'update',
    targetKind: 'model_roles',
    targetId: MODEL_ROLES_KV_KEY,
    before,
    after: next,
  });
  return c.json({ data: next });
});
