import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  createSandbox,
  DaytonaApiError,
  isMissingDaytonaSandbox,
  runPython,
} from './sandbox';
import type { Env } from '../types';

const env = {
  DAYTONA_API_KEY: 'test-key',
  DAYTONA_API_URL: 'https://daytona.test/api',
  DAYTONA_TOOLBOX_URL: 'https://daytona.test/toolbox',
} as Env;

afterEach(() => {
  vi.restoreAllMocks();
});

describe('Daytona sandbox wrapper', () => {
  it('creates Python sandboxes explicitly', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ id: 'sandbox-1' }), { status: 200 }),
    );

    await expect(createSandbox(env)).resolves.toBe('sandbox-1');

    expect(fetchMock).toHaveBeenCalledWith('https://daytona.test/api/sandbox', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer test-key',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ language: 'python' }),
    });
  });

  it('marks missing sandbox responses as recoverable', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('missing sandbox', { status: 404 }),
    );

    await expect(runPython(env, 'gone', 'print(1)')).rejects.toMatchObject({
      name: 'DaytonaApiError',
      status: 404,
    });

    const err = new DaytonaApiError('missing', 404, 'missing sandbox');
    expect(isMissingDaytonaSandbox(err)).toBe(true);
    expect(isMissingDaytonaSandbox(new DaytonaApiError('bad key', 401, ''))).toBe(false);
  });
});
