// product_id → PNC 充值包。上线前把 product_id / markup 换成真实值(见 spec 商品形态)。
// 利润只在卖包体现:markupSnapshot 随每笔 pack 落账,不进运行时配置。
export interface PncPack {
  pnc: number
  markupSnapshot: number
}

const PACKS: Record<string, Record<string, PncPack>> = {
  iap_ios: {
    'com.pendingbot.pnc.pack1': { pnc: 270, markupSnapshot: 2.0 },
  },
  polar_checkout: {
    polar_prod_pack1: { pnc: 270, markupSnapshot: 2.0 },
  },
}

export function resolvePack(source: string, productId: string): PncPack | null {
  return PACKS[source]?.[productId] ?? null
}
