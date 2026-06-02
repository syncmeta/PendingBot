import { describe, expect, it } from 'vitest'
import { resolvePack } from './billing-packs'

describe('billing-packs', () => {
  it('maps an iOS product id to a PNC pack', () => {
    const p = resolvePack('iap_ios', 'com.pendingbot.pnc.pack1')
    expect(p?.pnc).toBe(270)
    expect(p?.markupSnapshot).toBe(2.0)
  })
  it('maps a polar product id to a PNC pack', () => {
    expect(resolvePack('polar_checkout', 'polar_prod_pack1')?.pnc).toBe(270)
  })
  it('returns null for unknown product / source', () => {
    expect(resolvePack('iap_ios', 'nope')).toBeNull()
    expect(resolvePack('mystery', 'x')).toBeNull()
  })
})
