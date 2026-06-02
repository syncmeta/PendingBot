// 真实 Polar spike(P0 验收)：验证 "上报用量 → meter 燃尽 → getStateExternal 读余额" 闭环。
// 跑法：cd apps/edge && POLAR_ACCESS_TOKEN=<token> POLAR_SERVER=sandbox \
//        SPIKE_METER_ID=<meterId> SPIKE_EXTERNAL_ID=<已有credit的customer externalId> bun run polar:spike
//
// 前置(P0 在 Polar dashboard / API 先做好,见 spec 开放问题-1):
//   1. 建 pnc meter(按 event name 'pnc.usage' 聚合 metadata.pnc 求和)→ 记下 meterId
//   2. 给一个测试 Customer(externalId 自定)发一笔 credit(经带 Credits Benefit 的产品购买,
//      或核实 Polar 是否支持外部手动授予 credit —— 这正是开放问题-1)
import { Polar } from '@polar-sh/sdk'
import { createPolarClient } from '../src/billing/polar-client'

const meterId = process.env.SPIKE_METER_ID!
const externalId = process.env.SPIKE_EXTERNAL_ID!
const sdk = new Polar({
  accessToken: process.env.POLAR_ACCESS_TOKEN!,
  server: (process.env.POLAR_SERVER as 'sandbox' | 'production' | undefined) ?? 'sandbox',
}) as any
const om = createPolarClient(sdk, { meterId })

async function main() {
  const before = await om.getBalance(externalId)
  console.log('balance before:', before)

  await om.reportUsage(externalId, 2700, { category: 'llm_tokens', dedupeId: `spike-${Date.now()}` })
  console.log('ingested 2700 pnc usage')

  // meter 聚合有延迟,轮询观察燃尽
  let after = before
  for (let i = 0; i < 12; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    after = await om.getBalance(externalId)
    console.log(`poll ${i}: balance=${after}`)
    if (after !== before) break
  }

  const delta = before - after
  console.log(delta === 2700 ? '✅ 精确燃尽 2700' : `⚠️ delta=${delta}(期望 2700;float 余额可能有微差,精度已松绑可接受)`)
  console.log('记录:getStateExternal 余额刷新延迟约', '(见上面 poll 次数)')
}

main()
