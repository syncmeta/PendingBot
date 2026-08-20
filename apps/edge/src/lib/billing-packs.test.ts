import { afterEach, describe, expect, it } from 'vitest'
import { resolvePack, __resetPackCacheForTest, BILLING_PACKS_KV_KEY } from './billing-packs'
import type { Env } from '../types'

afterEach(() => __resetPackCacheForTest())

// env whose MEMORY KV returns the given override blob (null = no overrides).
const env = (blob: unknown = null): Env =>
  ({
    MEMORY: {
      get: async (key: string) => (key === BILLING_PACKS_KV_KEY ? blob : null),
      put: async () => {},
    },
  }) as unknown as Env

describe('billing-packs', () => {
  it('maps an iOS product id to a PNC pack (code default, empty KV)', async () => {
    const p = await resolvePack(env(), 'iap_ios', 'com.pendingbot.pnc.pack1')
    expect(p?.pnc).toBe(270)
    expect(p?.markupSnapshot).toBe(2.0)
  })
  it('maps a polar product id to a PNC pack (code default, empty KV)', async () => {
    expect((await resolvePack(env(), 'polar_checkout', 'polar_prod_pack1'))?.pnc).toBe(270)
  })
  it('returns null for unknown product / source', async () => {
    expect(await resolvePack(env(), 'iap_ios', 'nope')).toBeNull()
    expect(await resolvePack(env(), 'mystery', 'x')).toBeNull()
  })
  it('KV override wins per product id; other ids keep the code default', async () => {
    const e = env({
      iap_ios: {
        'com.pendingbot.pnc.real1': { pnc: 100, markupSnapshot: 1.5 },
        // 覆盖同一个默认 id 也生效
        'com.pendingbot.pnc.pack1': { pnc: 999, markupSnapshot: 3.0 },
      },
    })
    expect((await resolvePack(e, 'iap_ios', 'com.pendingbot.pnc.real1'))?.pnc).toBe(100)
    expect((await resolvePack(e, 'iap_ios', 'com.pendingbot.pnc.pack1'))?.pnc).toBe(999)
    // 未覆盖的通道仍走代码默认
    expect((await resolvePack(e, 'polar_checkout', 'polar_prod_pack1'))?.pnc).toBe(270)
  })
  it('ignores malformed override entries (falls back to code default)', async () => {
    const e = env({ iap_ios: { 'com.pendingbot.pnc.pack1': { pnc: -5 } } })
    expect((await resolvePack(e, 'iap_ios', 'com.pendingbot.pnc.pack1'))?.pnc).toBe(270)
  })
  it('never throws on KV failure (falls back to code default)', async () => {
    const e = {
      MEMORY: {
        get: async () => {
          throw new Error('kv down')
        },
      },
    } as unknown as Env
    expect((await resolvePack(e, 'iap_ios', 'com.pendingbot.pnc.pack1'))?.pnc).toBe(270)
  })
})
