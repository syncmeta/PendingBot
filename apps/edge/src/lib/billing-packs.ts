// product_id → PNC 充值包。两源合成(镜像 lib/model-roles.ts / feature-flags.ts):
//   - 代码默认(本文件):同步、不可失败的兜底。KV 为空时 byte-for-byte 旧行为,零回归。
//   - KV 覆盖(env.MEMORY 的 `cfg:billing-packs`):board「计费套餐」页在运行时写入。
//     ASC / Polar 建好真实 product id 后在 board 填映射即可生效,不用改代码发版。
// 解析语义:每个 product id 单独取 `KV 覆盖 ?? 代码默认`(product 级合并,
// 不是整表替换)。利润只在卖包体现:markupSnapshot 随每笔 pack 落账,不进运行时配置。
import type { Env } from '../types'

export interface PncPack {
  pnc: number
  markupSnapshot: number
}

/** 销售通道(= pnc_ledger.source 的充值来源)。加通道 = 加这里 + board 页自动跟上。 */
export const PACK_SOURCES = ['iap_ios', 'polar_checkout'] as const
export type PackSource = (typeof PACK_SOURCES)[number]

export type PackTable = Record<PackSource, Record<string, PncPack>>
export type PackOverrides = Partial<Record<PackSource, Record<string, PncPack>>>

/** KV key holding the override blob (shared with the board endpoint). */
export const BILLING_PACKS_KV_KEY = 'cfg:billing-packs'
const PACKS_TTL_MS = 60_000

/** 代码默认 = 上线前的占位 product id。真实值经 board 写 KV 覆盖。 */
export const BILLING_PACK_DEFAULTS: PackTable = {
  iap_ios: {
    'com.pendingbot.pnc.pack1': { pnc: 270, markupSnapshot: 2.0 },
  },
  polar_checkout: {
    polar_prod_pack1: { pnc: 270, markupSnapshot: 2.0 },
  },
}

// isolate-local cache(同 feature-flags.ts 的 TTL 模式):webhook 不是热路径,
// 但 KV 失败必须静默回退代码默认,绝不让入账 webhook 因 KV 抖动 500。
let cache: { at: number; v: PackOverrides } | null = null

async function loadOverrides(env: Env, now: number): Promise<PackOverrides> {
  if (cache && now - cache.at < PACKS_TTL_MS) return cache.v
  try {
    const v = (await env.MEMORY.get<PackOverrides>(BILLING_PACKS_KV_KEY, 'json')) ?? {}
    cache = { at: now, v }
    return v
  } catch {
    return cache?.v ?? {}
  }
}

/** Test-only: reset the isolate cache. */
export function __resetPackCacheForTest(): void {
  cache = null
}

function validPack(p: unknown): p is PncPack {
  if (!p || typeof p !== 'object') return false
  const { pnc, markupSnapshot } = p as PncPack
  return typeof pnc === 'number' && pnc > 0 && typeof markupSnapshot === 'number' && markupSnapshot > 0
}

/**
 * 解析 product_id → 充值包:KV 覆盖 ?? 代码默认。未知 source / product 返回 null。
 * 永不抛(KV 失败 → 代码默认)。`now` 可注入供测试。
 */
export async function resolvePack(
  env: Env,
  source: string,
  productId: string,
  now: number = Date.now(),
): Promise<PncPack | null> {
  const ov = await loadOverrides(env, now)
  const fromKv = (ov as Record<string, Record<string, unknown> | undefined>)[source]?.[productId]
  if (validPack(fromKv)) return fromKv
  return (BILLING_PACK_DEFAULTS as Record<string, Record<string, PncPack>>)[source]?.[productId] ?? null
}
