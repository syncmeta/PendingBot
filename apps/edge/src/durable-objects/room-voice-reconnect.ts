// Pure, side-effect-free helpers for the RoomVoiceDO ↔ media-container
// reconnect path. Kept out of room-voice.ts so the backoff schedule and
// the resync command-sequence builder are unit-testable without a live
// Durable Object or container — the end-to-end audio recovery itself is
// runtime-unverified (see docs/tech-debt.md), but this control logic is
// not.

import type { ContainerBotSpec, ControlCommand } from './room-media-protocol';

// Exponential backoff between reconnect attempts, capped. attempt is
// 0-based (the delay BEFORE attempt N). Schedule:
//   attempt 0 -> 250ms, 1 -> 500, 2 -> 1000, 3 -> 2000, 4 -> 4000,
//   5 -> 8000, 6+ -> 10000 (cap).
// Pure: same input -> same output, no clock, no randomness.
export const RECONNECT_BASE_MS = 250;
export const RECONNECT_MAX_MS = 10_000;

export function nextBackoffMs(attempt: number): number {
  if (!Number.isFinite(attempt) || attempt < 0) return RECONNECT_BASE_MS;
  const raw = RECONNECT_BASE_MS * 2 ** Math.floor(attempt);
  return Math.min(raw, RECONNECT_MAX_MS);
}

// Total reconnect budget. The DO gives up (hard-finalizes the call) once
// it has spent this long across attempts without a successful resync.
// With the schedule above, ~30s covers attempts at 0/250/750/1750/3750/
// 7750/15750/25750ms — i.e. ~8 dials before the wall-clock cap trips.
export const RECONNECT_MAX_WALL_MS = 30_000;

// Give-up decision for the reconnect loop, kept pure so the
// "retry vs hard-finalize" boundary is unit-testable. The DO calls this
// after a failed attempt: if even waiting `backoffMs` more would push
// total elapsed past the budget, stop retrying and finalize the call.
export function shouldGiveUpReconnect(
  elapsedMs: number,
  backoffMs: number,
  budgetMs: number = RECONNECT_MAX_WALL_MS,
): boolean {
  return elapsedMs + backoffMs > budgetMs;
}

// The ordered control-command sequence the DO replays to a fresh (or
// reset) container session to rebuild room state after a reconnect:
//   1. `start`     — arms (and on a warm instance, RESETS) the room.
//   2. `add-bot`   — one per bot, in the bots-snapshot order.
//
// The DO sends these only after it has seen `{t:'ready'}` from the new
// session. The container's `start` handler tears down any stale legs
// first (idempotent reset), so replaying this on a reused warm instance
// is safe. tool sets ride inside each ContainerBotSpec.tools, so no
// separate update-tools replay is needed for the base reconnect.
//
// Pure over its inputs — no DO state is read here; the caller snapshots
// the token / key / specs and hands them in.
export function buildResyncCommands(
  start: { token: string; openaiApiKey: string },
  specs: ContainerBotSpec[],
): ControlCommand[] {
  const cmds: ControlCommand[] = [
    { t: 'start', token: start.token, openaiApiKey: start.openaiApiKey },
  ];
  for (const spec of specs) {
    cmds.push({ t: 'add-bot', spec });
  }
  return cmds;
}
