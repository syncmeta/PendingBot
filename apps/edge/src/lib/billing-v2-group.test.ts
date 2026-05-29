import { describe, expect, it } from 'vitest';
import { computeShareNow, decayShareIndex } from './billing-v2-group';

describe('computeShareNow', () => {
  it('returns the full contribution when share_index has not decayed', () => {
    // Alice contributes 100 at share_index=1.0; nothing has been spent yet.
    // Her share_now should equal her contribution.
    expect(computeShareNow(100, 1.0, 1.0)).toBe(100);
  });

  it('shrinks proportionally as share_index decays', () => {
    // Alice contributed 1000 at share_index=1.0.
    // Group spent half: share_index dropped to 0.5.
    // Alice's share_now = 1000 * (0.5 / 1.0) = 500.
    expect(computeShareNow(1000, 1.0, 0.5)).toBe(500);
  });

  it('protects late contributors from historic spend', () => {
    // Alice joined at index=1.0, contributed 100.
    // Spend pushed index to 0.5.
    // Bob joins at index=0.5, contributes 100. Bob.share_index_at_join=0.5.
    // Group then spent some more: index dropped to 0.4.
    // Bob's share_now = 100 * (0.4 / 0.5) = 80.
    // Alice's share_now = 100 * (0.4 / 1.0) = 40.
    // → Alice ate more loss (40% remaining) than Bob (80% remaining). ✓
    expect(computeShareNow(100, 0.5, 0.4)).toBe(80);
    expect(computeShareNow(100, 1.0, 0.4)).toBe(40);
  });

  it('floors to never over-refund (fractional dust stays in pool)', () => {
    // 7 * (1/3) = 2.333... — should floor to 2.
    expect(computeShareNow(7, 3, 1)).toBe(2);
  });

  it('returns 0 for invalid / zero / negative inputs', () => {
    expect(computeShareNow(0, 1, 1)).toBe(0);
    expect(computeShareNow(-100, 1, 1)).toBe(0);
    expect(computeShareNow(100, 0, 1)).toBe(0);
    expect(computeShareNow(100, -1, 1)).toBe(0);
    expect(computeShareNow(100, 1, -0.5)).toBe(0);
    expect(computeShareNow(100, Number.NaN, 1)).toBe(0);
    expect(computeShareNow(100, 1, Number.NaN)).toBe(0);
  });

  it('handles full pool drain — share_now = 0 when current index = 0', () => {
    expect(computeShareNow(1000, 1.0, 0)).toBe(0);
  });
});

describe('decayShareIndex', () => {
  it('shrinks proportionally on a partial spend', () => {
    // Pool had 1000, spent 250 → newTotal=750. Old index=1.0.
    // newIndex = 1.0 * 750/1000 = 0.75.
    expect(decayShareIndex(1000, 750, 1.0)).toBe(0.75);
  });

  it('resets to 1.0 when pool empties (avoids divide-by-zero for next contrib)', () => {
    expect(decayShareIndex(1000, 0, 0.5)).toBe(1);
  });

  it('compounds across consecutive spends', () => {
    // Spend 1: 1000 → 800 ⇒ index 1.0 → 0.8
    const a = decayShareIndex(1000, 800, 1.0);
    expect(a).toBe(0.8);
    // Spend 2: 800 → 400 ⇒ index 0.8 → 0.4
    const b = decayShareIndex(800, 400, a);
    expect(b).toBeCloseTo(0.4, 10);
  });

  it('returns old index unchanged if oldTotal is 0 (no math possible)', () => {
    expect(decayShareIndex(0, 0, 0.42)).toBe(1); // newTotal=0 resets
    expect(decayShareIndex(0, 100, 0.42)).toBe(0.42); // safe passthrough
  });

  it('fairness invariant: ratio is preserved across two contributors', () => {
    // Alice contributed 100 at idx=1.0, Bob contributed 100 at idx=1.0.
    // Pool=200, idx=1.0. Group spends 50, newTotal=150, idx=0.75.
    // Alice share_now = 100 * 0.75/1.0 = 75. Bob share_now = 75.
    // Sum = 150 = newTotal. ✓ no leak.
    const newIdx = decayShareIndex(200, 150, 1.0);
    expect(newIdx).toBe(0.75);
    expect(computeShareNow(100, 1.0, newIdx) + computeShareNow(100, 1.0, newIdx)).toBe(150);
  });
});
