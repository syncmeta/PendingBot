import { describe, expect, it } from 'vitest'
import { PNC_PER_USD, MICROS_PER_PNC, usdToPncMicros, pncMicrosToPnc, pncToMicros } from './pnc'

describe('pnc', () => {
  it('exposes the product-fixed ratio', () => {
    expect(PNC_PER_USD).toBe(27)
    expect(MICROS_PER_PNC).toBe(1_000_000)
  })

  it('converts vendor USD cost to integer pnc_micros', () => {
    // $1 -> 27 PNC -> 27_000_000 micros
    expect(usdToPncMicros(1)).toBe(27_000_000)
    // cheap call $0.0001 -> 0.0027 PNC -> 2700 micros
    expect(usdToPncMicros(0.0001)).toBe(2700)
  })

  it('always returns an integer (no fractional micros)', () => {
    const v = usdToPncMicros(0.000033333)
    expect(Number.isInteger(v)).toBe(true)
  })

  it('formats micros back to PNC for display', () => {
    expect(pncMicrosToPnc(94_500_000)).toBeCloseTo(94.5, 6)
  })

  it('converts integer PNC pack face value to micros', () => {
    expect(pncToMicros(270)).toBe(270_000_000)
  })
})
