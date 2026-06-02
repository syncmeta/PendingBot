// 真实 OpenMeter spike(P0 验收)：建 subject+entitlement → grant 94_500_000
// → ingest 2700 → 读 balance。期望 balance == 94_497_300（整数精确）。
// 跑法：cd apps/edge && OPENMETER_API_KEY=<key> bun run om:spike
import { OpenMeter } from '@openmeter/sdk'
import { createOmClient, grantIdFor } from '../src/billing/om-client'

const sdk = new OpenMeter({
  baseUrl: process.env.OPENMETER_BASE_URL ?? 'https://openmeter.cloud',
  apiKey: process.env.OPENMETER_API_KEY!,
}) as any
const om = createOmClient(sdk)

async function main() {
  const subj = `spike-${process.env.SPIKE_ID ?? Math.floor(Date.now() / 1000)}`
  console.log('subject:', subj)
  await om.ensureSubject(subj)
  await om.ensureEntitlement(subj)

  await om.grantCredits(subj, 94_500_000, {
    externalId: grantIdFor('spike', subj),
    channel: 'spike',
    expiresInDays: 365,
  })

  await om.reportUsage(subj, 2700, { category: 'llm_tokens', dedupeId: `evt-${subj}-1` })

  // 事件聚合可能有秒级延迟，轮询
  let balance = -1
  for (let i = 0; i < 12; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    balance = await om.getBalance(subj)
    console.log(`poll ${i}: balance=${balance}`)
    if (balance === 94_497_300) break
  }

  const ok = balance === 94_497_300
  console.log(ok ? '✅ 精确：94_497_300' : `❌ 漂移：得到 ${balance}，期望 94_497_300`)
  process.exit(ok ? 0 : 1)
}

main()
