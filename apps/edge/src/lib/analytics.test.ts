import { beforeEach, describe, expect, it, vi } from 'vitest';

// Mock posthog-node before importing the helper so `new PostHog(...)` returns
// our spy instance — no network, no real client.
const captureImmediateMock = vi.fn(async () => {});
const flushMock = vi.fn(async () => {});
const ctorMock = vi.fn();
vi.mock('posthog-node', () => ({
  PostHog: class {
    constructor(...args: unknown[]) {
      ctorMock(...args);
    }
    captureImmediate = captureImmediateMock;
    flush = flushMock;
  },
}));

import { capture } from './analytics';
import type { Env } from '../types';

const baseArgs = { distinctId: 'user-1', event: 'message_sent', properties: { foo: 'bar' } };

beforeEach(() => {
  ctorMock.mockClear();
  captureImmediateMock.mockClear();
  flushMock.mockClear();
});

describe('analytics capture()', () => {
  it('is a no-op when POSTHOG_KEY is unset', async () => {
    const env = {} as Env;

    await capture(env, baseArgs);

    expect(ctorMock).not.toHaveBeenCalled();
    expect(captureImmediateMock).not.toHaveBeenCalled();
  });

  it('is a no-op when the observability kill-switch is off (even with a key)', async () => {
    const env = { POSTHOG_KEY: 'phc_test' } as Env; // POSTHOG_ENABLED unset → off

    await capture(env, baseArgs);

    expect(ctorMock).not.toHaveBeenCalled();
    expect(captureImmediateMock).not.toHaveBeenCalled();
  });

  it('sends the event immediately + flushes when POSTHOG_KEY is set', async () => {
    const env = { POSTHOG_ENABLED: 'true', POSTHOG_KEY: 'phc_test', POSTHOG_HOST: 'https://eu.i.posthog.com' } as Env;

    await capture(env, baseArgs);

    expect(ctorMock).toHaveBeenCalledWith(
      'phc_test',
      expect.objectContaining({ host: 'https://eu.i.posthog.com' }),
    );
    expect(captureImmediateMock).toHaveBeenCalledWith({
      distinctId: 'user-1',
      event: 'message_sent',
      properties: { foo: 'bar' },
    });
    expect(flushMock).toHaveBeenCalled();
  });

  it('swallows send failures (never throws into the caller)', async () => {
    const env = { POSTHOG_ENABLED: 'true', POSTHOG_KEY: 'phc_test' } as Env;
    captureImmediateMock.mockRejectedValueOnce(new Error('network down'));
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    await expect(capture(env, baseArgs)).resolves.toBeUndefined();
    expect(errSpy).toHaveBeenCalled();
    // Still drains even after a send failure.
    expect(flushMock).toHaveBeenCalled();

    errSpy.mockRestore();
  });
});
