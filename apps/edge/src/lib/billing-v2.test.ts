import { describe, expect, it } from 'vitest';
import {
  OVERDRAFT_BUFFER_PNC_MICROS,
  PNC_MICROS_PER_PNC,
  PNC_MICROS_PER_USD,
  PNC_PER_USD,
  THRESHOLD_LOW_PNC_MICROS,
  THRESHOLD_THROTTLE_PNC_MICROS,
  defaultPackExpiresAt,
  getThresholdState,
  usdToPncMicros,
} from './billing-v2';

describe('billing-v2 constants', () => {
  it('keeps the 27:1 ratio (product decision, not a bug)', () => {
    expect(PNC_PER_USD).toBe(27);
    expect(PNC_MICROS_PER_PNC).toBe(1_000_000);
    expect(PNC_MICROS_PER_USD).toBe(27_000_000);
  });

  it('low/throttle/overdraft thresholds match doc r2 §7', () => {
    expect(THRESHOLD_LOW_PNC_MICROS).toBe(50 * PNC_MICROS_PER_PNC);
    expect(THRESHOLD_THROTTLE_PNC_MICROS).toBe(5 * PNC_MICROS_PER_PNC);
    expect(OVERDRAFT_BUFFER_PNC_MICROS).toBe(500_000);
  });
});

describe('usdToPncMicros', () => {
  it('rounds 1 USD to exactly 27_000_000 micros', () => {
    expect(usdToPncMicros(1)).toBe(27_000_000);
  });

  it('rounds (not ceils) cheap calls to avoid systemic over-billing', () => {
    // 0.0001 USD * 27_000_000 = 2700 micros — round trip averages to 0.
    expect(usdToPncMicros(0.0001)).toBe(2700);
    // 0.00000001 USD = 0.27 micros; round → 0 (cheap call below grain).
    expect(usdToPncMicros(0.00000001)).toBe(0);
    // 0.00000002 USD = 0.54 micros; round → 1.
    expect(usdToPncMicros(0.00000002)).toBe(1);
  });

  it('clamps null / 0 / negative / non-finite to 0', () => {
    expect(usdToPncMicros(null)).toBe(0);
    expect(usdToPncMicros(undefined)).toBe(0);
    expect(usdToPncMicros(0)).toBe(0);
    expect(usdToPncMicros(-1)).toBe(0);
    expect(usdToPncMicros(Number.NaN)).toBe(0);
    expect(usdToPncMicros(Number.POSITIVE_INFINITY)).toBe(0);
  });
});

describe('getThresholdState', () => {
  it('≤ 0 → exhausted (hard stop, no-balance notice path)', () => {
    expect(getThresholdState(0)).toBe('exhausted');
    expect(getThresholdState(-1)).toBe('exhausted');
    expect(getThresholdState(-OVERDRAFT_BUFFER_PNC_MICROS)).toBe('exhausted');
  });

  it('(0, 5 PNC) → throttle (force cheap model, tools off)', () => {
    expect(getThresholdState(1)).toBe('throttle');
    expect(getThresholdState(PNC_MICROS_PER_PNC)).toBe('throttle');
    expect(getThresholdState(THRESHOLD_THROTTLE_PNC_MICROS - 1)).toBe('throttle');
  });

  it('[5 PNC, 50 PNC) → low (notice injected)', () => {
    expect(getThresholdState(THRESHOLD_THROTTLE_PNC_MICROS)).toBe('low');
    expect(getThresholdState(10 * PNC_MICROS_PER_PNC)).toBe('low');
    expect(getThresholdState(THRESHOLD_LOW_PNC_MICROS - 1)).toBe('low');
  });

  it('≥ 50 PNC → sufficient (no UX intervention)', () => {
    expect(getThresholdState(THRESHOLD_LOW_PNC_MICROS)).toBe('sufficient');
    expect(getThresholdState(1_000_000_000)).toBe('sufficient');
  });
});

describe('defaultPackExpiresAt', () => {
  it('adds 365 days (UTC) — §4', () => {
    const now = new Date('2026-05-29T10:00:00Z');
    const expiresAt = defaultPackExpiresAt(now);
    const expires = new Date(expiresAt);
    const diffMs = expires.getTime() - now.getTime();
    // 365 days = 365 * 86_400_000 ms = 31_536_000_000
    expect(diffMs).toBe(365 * 86_400_000);
  });

  it('returns an ISO string', () => {
    const out = defaultPackExpiresAt(new Date('2026-01-01T00:00:00Z'));
    expect(out).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(() => new Date(out)).not.toThrow();
  });
});
