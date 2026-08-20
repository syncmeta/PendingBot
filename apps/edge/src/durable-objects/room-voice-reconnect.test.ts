import { describe, expect, it } from 'vitest';
import {
  buildResyncCommands,
  nextBackoffMs,
  shouldGiveUpReconnect,
  RECONNECT_BASE_MS,
  RECONNECT_MAX_MS,
  RECONNECT_MAX_WALL_MS,
} from './room-voice-reconnect';
import type { ContainerBotSpec } from './room-media-protocol';

// Pure-logic tests for the RoomVoiceDO ↔ container reconnect path. The
// DO itself needs workerd globals (DurableObjectState), so we don't
// instantiate it here — instead we test the extracted pure helpers
// (backoff schedule, resync builder, give-up boundary) and compose them
// in a small fake reconnect loop with a mocked dial to pin the
// drop→reconnect state transitions: a drop sets `reconnecting` and does
// NOT finalize until the bounded retries are exhausted.

describe('nextBackoffMs', () => {
  it('follows the documented exponential schedule', () => {
    expect(nextBackoffMs(0)).toBe(250);
    expect(nextBackoffMs(1)).toBe(500);
    expect(nextBackoffMs(2)).toBe(1000);
    expect(nextBackoffMs(3)).toBe(2000);
    expect(nextBackoffMs(4)).toBe(4000);
    expect(nextBackoffMs(5)).toBe(8000);
  });

  it('caps at RECONNECT_MAX_MS for large attempts', () => {
    expect(nextBackoffMs(6)).toBe(RECONNECT_MAX_MS);
    expect(nextBackoffMs(7)).toBe(RECONNECT_MAX_MS);
    expect(nextBackoffMs(50)).toBe(RECONNECT_MAX_MS);
  });

  it('never undershoots the base and is robust to bad input', () => {
    expect(nextBackoffMs(0)).toBe(RECONNECT_BASE_MS);
    expect(nextBackoffMs(-1)).toBe(RECONNECT_BASE_MS);
    expect(nextBackoffMs(NaN)).toBe(RECONNECT_BASE_MS);
  });
});

describe('buildResyncCommands', () => {
  const spec = (botId: string): ContainerBotSpec => ({
    botId,
    model: 'gpt-realtime-2',
    instructions: 'hi',
    voice: 'marin',
    tools: [],
  });

  it('emits start first, then one add-bot per bot in order', () => {
    const cmds = buildResyncCommands(
      { token: 'tok', openaiApiKey: 'sk-test' },
      [spec('b1'), spec('b2'), spec('b3')],
    );
    expect(cmds).toHaveLength(4);
    expect(cmds[0]).toEqual({ t: 'start', token: 'tok', openaiApiKey: 'sk-test' });
    expect(cmds.slice(1).map((c) => c.t)).toEqual(['add-bot', 'add-bot', 'add-bot']);
    expect(cmds.slice(1).map((c) => (c as { spec: ContainerBotSpec }).spec.botId)).toEqual([
      'b1',
      'b2',
      'b3',
    ]);
  });

  it('emits just start when there are no bots (human-only room)', () => {
    const cmds = buildResyncCommands({ token: 'tok', openaiApiKey: 'k' }, []);
    expect(cmds).toEqual([{ t: 'start', token: 'tok', openaiApiKey: 'k' }]);
  });
});

describe('shouldGiveUpReconnect', () => {
  it('keeps retrying while elapsed + next backoff fits the budget', () => {
    expect(shouldGiveUpReconnect(0, 250, RECONNECT_MAX_WALL_MS)).toBe(false);
    expect(shouldGiveUpReconnect(10_000, 4_000, RECONNECT_MAX_WALL_MS)).toBe(false);
  });

  it('gives up once the next backoff would exceed the budget', () => {
    expect(shouldGiveUpReconnect(29_000, 8_000, RECONNECT_MAX_WALL_MS)).toBe(true);
    expect(shouldGiveUpReconnect(RECONNECT_MAX_WALL_MS, 1, RECONNECT_MAX_WALL_MS)).toBe(true);
  });
});

// A faithful in-test re-creation of the DO's reconnect loop using the
// same pure helpers, with a mock "dial" socket and a mock clock. Proves
// the state-transition invariants without workerd: drop → reconnecting,
// no finalize until either a successful resync or the budget runs out.
describe('reconnect loop state transitions (mocked socket + clock)', () => {
  interface LoopResult {
    finalized: boolean;
    resynced: boolean;
    attempts: number;
    reconnectingDuringLoop: boolean[];
  }

  // dialOutcomes[i] = does attempt i succeed? Runs the loop synchronously
  // over a virtual clock so we never touch real timers.
  function runLoop(dialOutcomes: boolean[]): LoopResult {
    let reconnecting = false;
    let finalized = false;
    let resynced = false;
    let attempt = 0;
    let elapsed = 0;
    const reconnectingDuringLoop: boolean[] = [];

    // The drop.
    reconnecting = true;
    expect(reconnecting).toBe(true);
    expect(finalized).toBe(false); // a drop must NOT finalize immediately

    while (reconnecting && !finalized) {
      reconnectingDuringLoop.push(reconnecting);
      const dialOk = dialOutcomes[attempt] ?? false;
      if (dialOk) {
        // resync send (always succeeds in this fake)
        resynced = true;
        reconnecting = false;
        break;
      }
      attempt += 1;
      const backoff = nextBackoffMs(attempt);
      if (shouldGiveUpReconnect(elapsed, backoff, RECONNECT_MAX_WALL_MS)) {
        reconnecting = false;
        finalized = true;
        break;
      }
      elapsed += backoff;
    }

    return { finalized, resynced, attempts: attempt, reconnectingDuringLoop };
  }

  it('recovers without finalizing when a later attempt succeeds', () => {
    // fail, fail, then succeed on the 3rd dial.
    const r = runLoop([false, false, true]);
    expect(r.resynced).toBe(true);
    expect(r.finalized).toBe(false);
    expect(r.attempts).toBe(2); // two failed before the success
    // stayed in reconnecting state the whole time it was retrying
    expect(r.reconnectingDuringLoop.every((x) => x === true)).toBe(true);
  });

  it('finalizes only after the wall-clock budget is exhausted', () => {
    // never succeeds — loop must terminate by give-up, not hang.
    const r = runLoop(Array(50).fill(false));
    expect(r.finalized).toBe(true);
    expect(r.resynced).toBe(false);
    // give-up happens within a bounded number of attempts (budget / cap),
    // proving it does not retry forever.
    expect(r.attempts).toBeGreaterThan(0);
    expect(r.attempts).toBeLessThan(20);
  });

  it('recovers on the very first re-dial (no finalize, no extra retries)', () => {
    const r = runLoop([true]);
    expect(r.resynced).toBe(true);
    expect(r.finalized).toBe(false);
    expect(r.attempts).toBe(0);
  });
});
