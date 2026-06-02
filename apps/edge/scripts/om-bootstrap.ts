// 一次性：创建 pnc meter + pnc feature。重复跑应幂等(已存在则忽略报错)。
// 跑法：cd apps/edge && OPENMETER_API_KEY=<key> bun run om:bootstrap
import { OpenMeter } from '@openmeter/sdk'
import { PNC_FEATURE_KEY, PNC_METER_SLUG, PNC_USAGE_EVENT_TYPE } from '../src/billing/om-client'

const sdk = new OpenMeter({
  baseUrl: process.env.OPENMETER_BASE_URL ?? 'https://openmeter.cloud',
  apiKey: process.env.OPENMETER_API_KEY!,
}) as any

async function main() {
  try {
    await sdk.meters.create({
      slug: PNC_METER_SLUG,
      aggregation: 'SUM',
      eventType: PNC_USAGE_EVENT_TYPE,
      valueProperty: '$.pnc_micros',
    })
    console.log('meter created:', PNC_METER_SLUG)
  } catch (e: any) {
    console.log('meter create skipped (maybe exists):', e?.message ?? e)
  }
  try {
    await sdk.features.create({ key: PNC_FEATURE_KEY, name: 'PNC', meterSlug: PNC_METER_SLUG })
    console.log('feature created:', PNC_FEATURE_KEY)
  } catch (e: any) {
    console.log('feature create skipped (maybe exists):', e?.message ?? e)
  }
}

main()
