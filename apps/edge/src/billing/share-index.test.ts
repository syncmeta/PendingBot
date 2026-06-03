import { describe, expect, it } from 'vitest';
import { computeShareNow } from './share-index';

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
});
