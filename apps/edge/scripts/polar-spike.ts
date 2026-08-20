// 自带建 meter + customer 的一键 P0 spike：验证 Polar 全事件钱包闭环。
// 跑法：cd apps/edge && POLAR_ACCESS_TOKEN=<token> POLAR_SERVER=sandbox bun run polar:spike
import { Polar } from '@polar-sh/sdk'
import { createPolarClient, PNC_EVENT_NAME, PNC_METADATA_KEY } from '../src/billing/polar-client'

const server = (process.env.POLAR_SERVER as 'sandbox' | 'production' | undefined) ?? 'sandbox'
const sdk = new Polar({ accessToken: process.env.POLAR_ACCESS_TOKEN!, server }) as any

function log(label: string, v: unknown) {
  console.log(label, JSON.stringify(v, null, 2))
}

async function main() {
  console.log('server:', server)

  // 1) 建 meter(SUM metadata.pnc，按事件名 pnc.usage 过滤)
  let meterId = process.env.SPIKE_METER_ID
  if (!meterId) {
    try {
      const meter = await sdk.meters.create({
        name: `pnc-spike-${Math.floor(Date.now() / 1000)}`,
        filter: {
          conjunction: 'and',
          clauses: [{ property: 'name', operator: 'eq', value: PNC_EVENT_NAME }],
        },
        aggregation: { func: 'sum', property: PNC_METADATA_KEY },
      })
      meterId = meter.id
      console.log('✅ meter created:', meterId)
    } catch (e: any) {
      console.error('❌ meter create failed:', e?.message ?? e, e?.body$ ?? e?.detail ?? '')
      throw e
    }
  }

  // 2) 建 customer(externalId = 我们的 subject_id)
  const externalId = `spike-${Math.floor(Date.now() / 1000)}`
  try {
    const c = await sdk.customers.create({ email: `${externalId}@gmail.com`, externalId })
    console.log('✅ customer created:', c.id, 'externalId:', externalId)
  } catch (e: any) {
    console.error('❌ customer create failed:', e?.message ?? e, e?.body$ ?? e?.detail ?? '')
    throw e
  }

  const om = createPolarClient(sdk, { meterId: meterId! })

  // 3) 充值 94_500_000(负值事件)
  await om.grantCredits(externalId, 94_500_000, { source: 'spike', dedupeId: `grant-${externalId}` })
  console.log('→ granted 94_500_000')

  // 4) 扣费 2700(正值事件)
  await om.reportUsage(externalId, 2700, { category: 'llm_tokens', dedupeId: `use-${externalId}` })
  console.log('→ used 2700')

  // 5) 轮询读余额
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    const state = await sdk.customers.getStateExternal({ externalId })
    const meters = state.activeMeters ?? state.active_meters ?? []
    log(`poll ${i} activeMeters`, meters)
    const m = meters.find((x: any) => (x.meterId ?? x.meter_id) === meterId)
    if (m && (m.balance ?? 0) !== 0) {
      console.log(`\n=== 结果 ===\nbalance=${m.balance}  consumed=${m.consumedUnits ?? m.consumed_units}  credited=${m.creditedUnits ?? m.credited_units}`)
      console.log('期望:充值94_500_000 − 用2700 = 可用 94_497_300(符号以实际为准)')
      break
    }
  }
}

main().catch((e) => {
  console.error('SPIKE FAILED:', e?.message ?? e)
  process.exit(1)
})
