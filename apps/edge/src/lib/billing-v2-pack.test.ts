import { describe, expect, it } from 'vitest';
import { usdCentsToPncMicrosViaMarkup } from './billing-v2-pack';
import { PNC_MICROS_PER_USD } from './billing-v2';

describe('usdCentsToPncMicrosViaMarkup', () => {
  it('passes through at markup=1 (sells PNC at cost — no platform margin)', () => {
    // $1.00 (100 cents) at markup=1 → 27_000_000 micros (full 1 USD worth).
    expect(usdCentsToPncMicrosViaMarkup(100, 1)).toBe(PNC_MICROS_PER_USD);
  });

  it('shrinks PNC count as markup rises (higher margin)', () => {
    // $1 at 2.0× markup → 1/2 USD worth of PNC = 13_500_000 micros.
    expect(usdCentsToPncMicrosViaMarkup(100, 2.0)).toBe(13_500_000);
    // $1 at 2.7× markup → 10_000_000 micros (a clean 10 PNC at the IAP default).
    expect(usdCentsToPncMicrosViaMarkup(100, 2.7)).toBe(10_000_000);
  });

  it('floors fractional micros (favours platform on the sale side)', () => {
    // $9.99 at 1.5× markup = 9.99/1.5 × 27_000_000 = 179_820_000.
    expect(usdCentsToPncMicrosViaMarkup(999, 1.5)).toBe(179_820_000);
  });

  it('returns 0 for invalid inputs', () => {
    expect(usdCentsToPncMicrosViaMarkup(0, 2)).toBe(0);
    expect(usdCentsToPncMicrosViaMarkup(-100, 2)).toBe(0);
    expect(usdCentsToPncMicrosViaMarkup(100, 0)).toBe(0);
    expect(usdCentsToPncMicrosViaMarkup(100, -1)).toBe(0);
    expect(usdCentsToPncMicrosViaMarkup(Number.NaN, 2)).toBe(0);
    expect(usdCentsToPncMicrosViaMarkup(100, Number.POSITIVE_INFINITY)).toBe(0);
  });
});
