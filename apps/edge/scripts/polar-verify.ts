// 直接用 Polar API 端到端验证 P1 资金流(不经 webhook/dashboard):
//   建客户 → 充值(grant 负值)→ 重复充值(同 dedupeId,应被去重)→ 扣费(usage 正值)
//   → 退款(reduce 正值)→ 读余额,核对数学 + 幂等。
// 跑法:cd apps/edge && POLAR_ACCESS_TOKEN=<token> POLAR_SERVER=sandbox \
//        SPIKE_METER_ID=<meterId> bun run scripts/polar-verify.ts
import { Polar } from '@polar-sh/sdk'
import { createPolarClient } from '../src/billing/polar-client'

const sdk = new Polar({
  accessToken: process.env.POLAR_ACCESS_TOKEN!,
  server: (process.env.POLAR_SERVER as 'sandbox' | 'production' | undefined) ?? 'sandbox',
}) as any

async function ensureMeter(): Promise<string> {
  if (process.env.SPIKE_METER_ID) return process.env.SPIKE_METER_ID
  const m = await sdk.meters.create({
    name: `pnc-verify-${Math.floor(Date.now() / 1000)}`,
    filter: { conjunction: 'and', clauses: [{ property: 'name', operator: 'eq', value: 'pnc.usage' }] },
    aggregation: { func: 'sum', property: 'pnc' },
  })
  return m.id
}

async function balance(om: any, ext: string): Promise<number> {
  return om.getBalance(ext)
}

async function waitFor(om: any, ext: string, want: number, label: string) {
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    const b = await balance(om, ext)
    if (b === want) {
      console.log(`✅ ${label}: balance=${b}`)
      return
    }
    if (i === 19) console.log(`❌ ${label}: got ${b}, want ${want}`)
  }
}

async function main() {
  const meterId = await ensureMeter()
  console.log('meter:', meterId)
  const ext = `verify-${Math.floor(Date.now() / 1000)}`
  await sdk.customers.create({ email: `${ext}@gmail.com`, externalId: ext })
  console.log('customer externalId:', ext)
  const om = createPolarClient(sdk, { meterId })

  // 1) 充值 270_000_000(负值事件)
  await om.grantCredits(ext, 270_000_000, { source: 'verify', dedupeId: `G1-${ext}` })
  // 2) 重复同 dedupeId —— 应被 Polar external_id 去重,不重复加
  await om.grantCredits(ext, 270_000_000, { source: 'verify', dedupeId: `G1-${ext}` })
  await waitFor(om, ext, 270_000_000, '充值+去重(重复不翻倍)')

  // 3) 扣费 2700(正值)
  await om.reportUsage(ext, 2700, { category: 'llm_tokens', dedupeId: `U1-${ext}` })
  await waitFor(om, ext, 270_000_000 - 2700, '扣费 2700')

  // 4) 退款 1000(reduceCredits 正值)
  await om.reduceCredits(ext, 1000, { source: 'verify_refund', dedupeId: `R1-${ext}` })
  await waitFor(om, ext, 270_000_000 - 2700 - 1000, '退款 1000')

  console.log('\n最终期望余额:', 270_000_000 - 2700 - 1000)
}

main().catch((e) => {
  console.error('VERIFY FAILED:', e?.message ?? e)
  process.exit(1)
})
