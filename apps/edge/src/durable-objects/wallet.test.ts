import { describe, expect, it } from 'vitest';
import { thresholdOf } from './wallet';

// 门禁 4 档(micros;1 PNC = 1_000_000):
//   ≥50 PNC 充足 / [5,50) 提醒 / (0,5) 节流 / ≤0 硬停
describe('wallet thresholdOf', () => {
  it('sufficient at/above 50 PNC', () => {
    expect(thresholdOf(50_000_000)).toBe('sufficient');
    expect(thresholdOf(123_000_000)).toBe('sufficient');
  });
  it('low in [5,50) PNC', () => {
    expect(thresholdOf(49_999_999)).toBe('low');
    expect(thresholdOf(5_000_000)).toBe('low');
  });
  it('throttle in (0,5) PNC', () => {
    expect(thresholdOf(4_999_999)).toBe('throttle');
    expect(thresholdOf(1)).toBe('throttle');
  });
  it('exhausted at 0 or negative (incl. overdraft band)', () => {
    expect(thresholdOf(0)).toBe('exhausted');
    expect(thresholdOf(-1)).toBe('exhausted');
    expect(thresholdOf(-500_000)).toBe('exhausted'); // overdraft floor 仍是硬停档
  });
});
