import { beforeEach, describe, expect, it, vi } from 'vitest';

// Mock the analytics seam so trackEvent's only observable effect is "did it
// hand a well-formed event to capture(), fire-and-forget".
const captureMock = vi.fn(async (_env: unknown, _args: unknown) => {});
// Reference the spy lazily (inside a fn body) so vi.mock's hoisting doesn't
// touch captureMock before its `const` is initialized (TDZ).
vi.mock('./analytics', () => ({
  capture: (env: unknown, args: unknown) => captureMock(env, args),
}));

import { trackEvent, AnalyticsEvent } from './track';
import type { Context } from 'hono';
import type { AppBindings } from '../types';

function fakeCtx(userId: string | undefined) {
  const waitUntil = vi.fn();
  const env = { POSTHOG_ENABLED: 'true', POSTHOG_KEY: 'phc_test' };
  const c = {
    env,
    var: { userId },
    executionCtx: { waitUntil },
  } as unknown as Context<AppBindings>;
  return { c, waitUntil, env };
}

beforeEach(() => captureMock.mockClear());

describe('trackEvent()', () => {
  it('captures the event for the request user, fire-and-forget via waitUntil', () => {
    const { c, waitUntil, env } = fakeCtx('user-1');

    trackEvent(c, AnalyticsEvent.MessageSent, { conversation_id: 'conv-1', has_attachment: true });

    // Scheduled on the execution context, not awaited on the hot path.
    expect(waitUntil).toHaveBeenCalledTimes(1);
    expect(captureMock).toHaveBeenCalledWith(env, {
      distinctId: 'user-1',
      event: 'message_sent',
      properties: { conversation_id: 'conv-1', has_attachment: true },
    });
  });

  it('is a no-op for unauthenticated requests (no userId)', () => {
    const { c, waitUntil } = fakeCtx(undefined);

    trackEvent(c, AnalyticsEvent.GroupCreated, { group_id: 'g-1' });

    expect(waitUntil).not.toHaveBeenCalled();
    expect(captureMock).not.toHaveBeenCalled();
  });

  it('exposes stable snake_case event names', () => {
    expect(AnalyticsEvent.VoiceCallStarted).toBe('voice_call_started');
    expect(AnalyticsEvent.TopupSucceeded).toBe('topup_succeeded');
    expect(AnalyticsEvent.GroupJoined).toBe('group_joined');
  });
});
