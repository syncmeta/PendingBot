import type { MiddlewareHandler } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from './http-error';
import { serviceClient } from './supabase';
import type { AppBindings } from '../types';

type DbError = { message: string };
type GrantRow = {
  id?: unknown;
  subject_id?: unknown;
  granted_by_user_id?: unknown;
  grant_kind?: unknown;
  scopes?: unknown;
  app_kind?: unknown;
  status?: unknown;
  expires_at?: unknown;
};
type UntypedDb = {
  from(table: string): {
    select(columns: string): {
      eq(column: string, value: unknown): {
        maybeSingle(): Promise<{ data: GrantRow | null; error: DbError | null }>;
      };
    };
    update(patch: Record<string, unknown>): {
      eq(column: string, value: unknown): Promise<{ error: DbError | null }>;
    };
  };
};

function untypedDb(env: AppBindings['Bindings']): UntypedDb {
  return serviceClient(env) as unknown as UntypedDb;
}

function bearerToken(header: string | undefined): string | null {
  const match = /^Bearer\s+(.+)$/i.exec(header ?? '');
  return match?.[1]?.trim() || null;
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function normalizeScopes(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((scope): scope is string => typeof scope === 'string') : [];
}

function isExpired(expiresAt: unknown): boolean {
  if (typeof expiresAt !== 'string' || !expiresAt) return false;
  return new Date(expiresAt).getTime() <= Date.now();
}

export function hasDeviceScope(c: Parameters<MiddlewareHandler<AppBindings>>[0], scope: string): boolean {
  return c.var.deviceGrant?.scopes.includes(scope) === true;
}

export function requireSubjectAuth(requiredScopes: string[] = []): MiddlewareHandler<AppBindings> {
  const sessionMiddleware = requireSession() as unknown as MiddlewareHandler<AppBindings>;
  return async (c, next) => {
    const token = bearerToken(c.req.header('authorization'));
    if (!token?.startsWith('pdg_')) {
      await sessionMiddleware(c, async () => {
        c.set('authKind', 'supabase_jwt');
        await next();
      });
      return;
    }

    const tokenHash = await sha256Hex(token);
    const svc = untypedDb(c.env);
    const { data: grant, error } = await svc
      .from('subject_device_grants')
      .select('id, subject_id, granted_by_user_id, grant_kind, scopes, app_kind, status, expires_at')
      .eq('token_hash', tokenHash)
      .maybeSingle();
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    if (!grant || grant.status !== 'active' || isExpired(grant.expires_at)) {
      return jsonError(c, 401, 'unauthorized');
    }

    const scopes = normalizeScopes(grant.scopes);
    if (!requiredScopes.every((scope) => scopes.includes(scope))) {
      return jsonError(c, 403, 'forbidden');
    }
    if (
      typeof grant.id !== 'string' ||
      typeof grant.subject_id !== 'string' ||
      typeof grant.grant_kind !== 'string' ||
      typeof grant.app_kind !== 'string'
    ) {
      return jsonError(c, 401, 'unauthorized');
    }

    c.set('authKind', 'device_grant');
    c.set('deviceGrant', {
      id: grant.id,
      subjectId: grant.subject_id,
      grantedByUserId: typeof grant.granted_by_user_id === 'string' ? grant.granted_by_user_id : null,
      grantKind: grant.grant_kind,
      scopes,
      appKind: grant.app_kind,
    });
    await svc
      .from('subject_device_grants')
      .update({ last_used_at: new Date().toISOString() })
      .eq('id', grant.id);
    await next();
  };
}
