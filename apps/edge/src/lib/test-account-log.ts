// Verbose request log for accounts flagged `is_test_account = true`.
//
// Flow:
//   1. Middleware `testAccountLogger()` mounts globally; after a request
//      finishes, if c.var.userId is set and the user is a test account,
//      it writes one row into pendingbot.test_account_log with route,
//      status, latency, and a small payload slice. Lookups for the flag
//      are cached in KV (5 min) so the per-request hot path costs at
//      most one KV read.
//   2. Route code can call `logTestEvent(c, { kind, payload })` to add
//      finer-grained entries (e.g. before/after an LLM call, on a
//      specific branch). Same gate applies — no-op for production users.
//
// Production users incur no DB write. The flag check is a single KV
// read on cold paths and free on warm paths.

import type { Context } from 'hono';
import type { MiddlewareHandler } from 'hono';
import type { AppBindings, Env } from '../types';
import { serviceClient } from './supabase';
import { safeWaitUntil } from './safe-wait-until';

const FLAG_PREFIX = 'test-account:';
// Short TTL: the board flips this flag for live debugging and there's
// no cross-system invalidation path. 60s keeps the per-request cost
// down (1 DB round-trip per user per minute) while staying responsive
// to admins watching test-account_log fill in.
const FLAG_TTL_SEC = 60;
export const TEST_ACCOUNT_LOG_RETENTION_DAYS = 14;

type FlagCache = { is_test_account: boolean };

async function isTestAccount(env: Env, userId: string): Promise<boolean> {
  const cached = await env.MEMORY.get<FlagCache>(FLAG_PREFIX + userId, 'json');
  if (cached) return cached.is_test_account;
  const supa = serviceClient(env);
  const { data } = await supa
    .from('users')
    .select('is_test_account')
    .eq('id', userId)
    .maybeSingle();
  const flag = Boolean(data?.is_test_account);
  await env.MEMORY.put(FLAG_PREFIX + userId, JSON.stringify({ is_test_account: flag }), {
    expirationTtl: FLAG_TTL_SEC,
  });
  return flag;
}

/// Invalidate the cached flag for a user — call from board actions
/// that flip is_test_account so the next request re-reads from DB.
export async function invalidateTestAccountFlag(env: Env, userId: string): Promise<void> {
  await env.MEMORY.delete(FLAG_PREFIX + userId);
}

export interface TestEvent {
  kind: string;
  route?: string;
  method?: string;
  status?: number;
  latencyMs?: number;
  requestId?: string;
  note?: string;
  payload?: Record<string, unknown>;
}

export function summarizeQueryKeys(query: Record<string, unknown>): string[] {
  return Object.keys(query).filter(Boolean).sort();
}

async function insertEvent(env: Env, userId: string, event: TestEvent): Promise<void> {
  const supa = serviceClient(env);
  await supa.from('test_account_log').insert({
    user_id: userId,
    kind: event.kind,
    route: event.route ?? null,
    method: event.method ?? null,
    status: event.status ?? null,
    latency_ms: event.latencyMs ?? null,
    request_id: event.requestId ?? null,
    note: event.note ?? null,
    payload: (event.payload ?? {}) as never,
  });
}

/// Log a custom test-account event from route code. No-op when the
/// caller is not a test account. Returns immediately; the actual
/// insert is scheduled via waitUntil so the response isn't blocked.
export function logTestEvent(c: Context<AppBindings>, event: TestEvent): void {
  const userId = c.var.userId;
  if (!userId) return;
  safeWaitUntil(
    c,
    (async () => {
      try {
        if (!(await isTestAccount(c.env, userId))) return;
        await insertEvent(c.env, userId, event);
      } catch (err) {
        console.error('[test-account-log] event insert failed', err);
      }
    })(),
  );
}

/// Global middleware: capture every request from a test account into
/// pendingbot.test_account_log. The insert is async via waitUntil so
/// it never delays the response. Non-test accounts pay only one KV
/// read (and only when userId is set, i.e. after auth).
export function testAccountLogger(): MiddlewareHandler<AppBindings> {
  return async (c, next) => {
    const start = Date.now();
    let errMessage: string | undefined;
    try {
      await next();
    } catch (err) {
      errMessage = err instanceof Error ? err.message : String(err);
      throw err;
    } finally {
      const userId = c.var.userId;
      if (userId) {
        const latencyMs = Date.now() - start;
        const status = c.res?.status;
        const route = c.req.path;
        const method = c.req.method;
        const requestId = c.req.header('cf-ray') ?? undefined;
        safeWaitUntil(
          c,
          (async () => {
            try {
              if (!(await isTestAccount(c.env, userId))) return;
              await insertEvent(c.env, userId, {
                kind: errMessage ? 'error' : 'http_request',
                route,
                method,
                status,
                latencyMs,
                requestId,
                note: errMessage,
                payload: {
                  query_keys: summarizeQueryKeys(c.req.query()),
                  client_version: c.req.header('x-client-version') ?? null,
                  client_platform: c.req.header('x-client-platform') ?? null,
                  country: c.req.header('cf-ipcountry') ?? null,
                },
              });
            } catch (err) {
              console.error('[test-account-log] request insert failed', err);
            }
          })(),
        );
      }
    }
  };
}
