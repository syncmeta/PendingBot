// Product-analytics event seam for route handlers (dashboard stack, block 1).
//
// Thin wrapper over lib/analytics.capture() that pulls the acting user from
// the Hono context and fires the event fire-and-forget via safeWaitUntil, so
// analytics never blocks (or breaks) the request it's observing. capture()
// is itself a no-op when POSTHOG_KEY is unset, so this whole path is dormant
// until PostHog is configured. See docs/superpowers/specs/2026-06-01-dashboard-stack-design.md.
//
// Privacy: we only ever pass the EXPLICIT `properties` a call site supplies —
// never the request body, message content, or PII. Keep it that way (the
// spec's privacy rule: no content/prompt/PII into analytics).

import type { Context } from 'hono';
import type { AppBindings } from '../types';
import { capture } from './analytics';
import { safeWaitUntil } from './safe-wait-until';

/**
 * Canonical product-event names emitted by the edge backend. Centralized so a
 * typo can't silently fork an event into two PostHog series. Names + property
 * conventions follow the event spec in the dashboard-stack design doc.
 *
 * NOTE: `signed_up` and `bot_created` are intentionally NOT here — user/subject
 * creation is a Supabase signup trigger and bot creation is a client-direct
 * insert, so neither has a server-side seam. Those fire from the iOS PostHog
 * SDK instead (see docs/tech-debt.md).
 */
export const AnalyticsEvent = {
  MessageSent: 'message_sent',
  GroupCreated: 'group_created',
  GroupJoined: 'group_joined',
  GroupSubjectCreated: 'group_subject_created',
  GroupToppedUp: 'group_topped_up',
  TopupSucceeded: 'topup_succeeded',
  VoiceCallStarted: 'voice_call_started',
  VoiceCallEnded: 'voice_call_ended',
} as const;

export type AnalyticsEventName = (typeof AnalyticsEvent)[keyof typeof AnalyticsEvent];

/**
 * Capture a product-analytics event for the user behind this request.
 *
 * Fire-and-forget: scheduled via executionCtx.waitUntil (so it survives the
 * isolate past the response) and never awaited on the hot path. No-op when
 * there's no identified user (pre-auth requests) or when PostHog is unset.
 */
export function trackEvent(
  c: Context<AppBindings>,
  event: AnalyticsEventName,
  properties?: Record<string, unknown>,
): void {
  const distinctId = c.var.userId;
  if (!distinctId) return; // unauthenticated path — nothing to attribute to.
  safeWaitUntil(c, capture(c.env, { distinctId, event, properties }));
}
