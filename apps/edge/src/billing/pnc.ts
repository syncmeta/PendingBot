// Pending Name Credits 单位换算。见 docs/billing-v2-design.md §2。
// 产品不变量：27 PNC = 1 USD（故意不整除，防心算，降消费痛感——别改回 100/1000）。
// 内部一律用整数 micros，禁止每事件四舍五入造成系统性放大/漏计。
export const PNC_PER_USD = 27
export const MICROS_PER_PNC = 1_000_000

/** 供应商真实成本(USD) → 整数 pnc_micros。只在此处取整。 */
export function usdToPncMicros(vendorCostUsd: number): number {
  return Math.round(vendorCostUsd * PNC_PER_USD * MICROS_PER_PNC)
}

/** pnc_micros → PNC(仅供 UI/日志展示,不参与账本运算)。 */
export function pncMicrosToPnc(micros: number): number {
  return micros / MICROS_PER_PNC
}

/** 整数 PNC → 整数 pnc_micros(充值包面值用)。 */
export function pncToMicros(pnc: number): number {
  return Math.round(pnc * MICROS_PER_PNC)
}
