import { describe, expect, it } from 'vitest';
import { computeShareNow, decayShareIndex } from './share-index';

describe('share-index math', () => {
  it('computeShareNow floors to avoid over-refund', () => {
    // 注资 100 micros,join 时 index=1.0,当前 index=0.5 → 还剩 50
    expect(computeShareNow(100, 1.0, 0.5)).toBe(50);
    // 晚注资者 join index 已是 0.5,当前还是 0.5 → 不沾历史消耗,全额
    expect(computeShareNow(100, 0.5, 0.5)).toBe(100);
    // floor:101 * 0.5 = 50.5 → 50
    expect(computeShareNow(101, 1.0, 0.5)).toBe(50);
  });

  it('computeShareNow guards bad input', () => {
    expect(computeShareNow(100, 0, 0.5)).toBe(0);
    expect(computeShareNow(100, -1, 0.5)).toBe(0);
    expect(computeShareNow(-5, 1, 1)).toBe(0);
    expect(computeShareNow(100, 1, -1)).toBe(0);
    expect(computeShareNow(100, 1, NaN)).toBe(0);
  });

  it('decayShareIndex shrinks proportionally', () => {
    // 池 1000 花 200 → 新 index = 1.0 * 800/1000 = 0.8
    expect(decayShareIndex(1000, 800, 1.0)).toBeCloseTo(0.8, 10);
    // 已 0.8 再花一半 → 0.4
    expect(decayShareIndex(800, 400, 0.8)).toBeCloseTo(0.4, 10);
  });

  it('decayShareIndex resets to 1 when pool empties', () => {
    expect(decayShareIndex(1000, 0, 0.8)).toBe(1);
    expect(decayShareIndex(1000, -5, 0.8)).toBe(1);
  });

  it('decayShareIndex keeps index when old total non-positive', () => {
    expect(decayShareIndex(0, 100, 0.7)).toBe(0.7);
  });
});
