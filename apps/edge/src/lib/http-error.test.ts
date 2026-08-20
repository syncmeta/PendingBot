import { describe, expect, it } from 'vitest';
import type { Context } from 'hono';
import { Hono } from 'hono';
import { jsonError, type ApiErrorBody } from './http-error';
import type { AppBindings } from '../types';

// jsonError is the only path every /v1 route uses for non-2xx
// responses. The envelope shape is part of the worker's external
// contract (iOS APIClient.validate parses it; future LLM error
// analysis reads `code`), so changes here propagate everywhere. These
// tests pin: response shape, content-type, status, and the three
// optional fields' presence semantics.

type Handler = (c: Context<AppBindings>) => Response;

async function call(
  handler: Handler,
): Promise<{ status: number; body: ApiErrorBody; contentType: string | null }> {
  const app = new Hono<AppBindings>();
  app.get('/x', handler);
  const res = await app.request('/x');
  const body = (await res.json()) as ApiErrorBody;
  return {
    status: res.status,
    body,
    contentType: res.headers.get('content-type'),
  };
}

describe('jsonError envelope', () => {
  it('wraps the code under the `error` key', async () => {
    const r = await call((c) => jsonError(c, 400, 'invalid_body'));
    expect(r.status).toBe(400);
    expect(r.body).toEqual({ error: { code: 'invalid_body' } });
  });

  it('keeps message when supplied', async () => {
    const r = await call((c) =>
      jsonError(c, 403, 'forbidden', { message: '只能改自己创建的私有机器人' }),
    );
    expect(r.status).toBe(403);
    expect(r.body).toEqual({
      error: { code: 'forbidden', message: '只能改自己创建的私有机器人' },
    });
  });

  it('keeps detail when supplied (structured payload)', async () => {
    const r = await call((c) =>
      jsonError(c, 413, 'quota_exceeded', {
        detail: {
          quota_bytes: 5_368_709_120,
          used_bytes: 5_368_000_000,
          attempted_bytes: 1_048_576,
        },
      }),
    );
    expect(r.status).toBe(413);
    expect(r.body).toEqual({
      error: {
        code: 'quota_exceeded',
        detail: {
          quota_bytes: 5_368_709_120,
          used_bytes: 5_368_000_000,
          attempted_bytes: 1_048_576,
        },
      },
    });
  });

  it('keeps both message + detail when supplied', async () => {
    const r = await call((c) =>
      jsonError(c, 413, 'quota_exceeded', {
        message: '云端附件存储已达上限,请先删除一些旧的附件再试',
        detail: { used_bytes: 1 },
      }),
    );
    expect(r.body.error.message).toBe('云端附件存储已达上限,请先删除一些旧的附件再试');
    expect(r.body.error.detail).toEqual({ used_bytes: 1 });
  });

  it('drops message when undefined (no `message: undefined` in JSON)', async () => {
    // Important — iOS branches on key presence, not value === undefined.
    // A round-trip through JSON.stringify would already drop undefined,
    // but the helper builds the object before serialization, so we want
    // it to never *include* the key when no message was passed.
    const r = await call((c) => jsonError(c, 404, 'not_found'));
    expect(Object.keys(r.body.error)).toEqual(['code']);
  });

  it('drops detail when undefined', async () => {
    const r = await call((c) => jsonError(c, 401, 'unauthorized'));
    expect(Object.keys(r.body.error).sort()).toEqual(['code']);
  });

  it('serves application/json', async () => {
    const r = await call((c) => jsonError(c, 400, 'invalid_body'));
    expect(r.contentType).toMatch(/application\/json/);
  });

  it('serializes detail values that include null, arrays, nested objects', async () => {
    const r = await call((c) =>
      jsonError(c, 500, 'database_error', {
        detail: { code: null, hints: [1, 2, 3], inner: { k: 'v' } },
      }),
    );
    expect(r.body.error.detail).toEqual({
      code: null,
      hints: [1, 2, 3],
      inner: { k: 'v' },
    });
  });
});
