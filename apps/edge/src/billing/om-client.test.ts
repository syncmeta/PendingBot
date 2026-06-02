import { describe, expect, it, vi } from 'vitest'
import { createOmClient, PNC_FEATURE_KEY, grantIdFor } from './om-client'

function fakeSdk() {
  return {
    subjects: { upsert: vi.fn().mockResolvedValue([{ key: 's1' }]) },
    entitlementsV1: {
      create: vi.fn().mockResolvedValue({ id: 'ent_1' }),
      value: vi
        .fn()
        .mockResolvedValue({ hasAccess: true, balance: 94_497_300, usage: 2700, overage: 0 }),
      grants: {
        create: vi.fn().mockResolvedValue({ id: 'grant_1' }),
        void: vi.fn().mockResolvedValue(undefined),
      },
    },
    events: { ingest: vi.fn().mockResolvedValue(undefined) },
  }
}

describe('om-client', () => {
  it('uses the fixed pnc feature key', () => {
    expect(PNC_FEATURE_KEY).toBe('pnc')
  })

  it('builds a deterministic grant id from external purchase id (idempotency)', () => {
    expect(grantIdFor('iap_ios', 'txn_abc')).toBe(grantIdFor('iap_ios', 'txn_abc'))
    expect(grantIdFor('iap_ios', 'txn_abc')).not.toBe(grantIdFor('lemon_squeezy', 'txn_abc'))
  })

  it('getBalance returns integer micros from entitlement value', async () => {
    const om = createOmClient(fakeSdk() as any)
    const bal = await om.getBalance('s1')
    expect(bal).toBe(94_497_300)
    expect(Number.isInteger(bal)).toBe(true)
  })

  it('grantCredits passes integer micros amount + fixed feature key', async () => {
    const sdk = fakeSdk()
    const om = createOmClient(sdk as any)
    await om.grantCredits('s1', 94_500_000, {
      externalId: 'txn_abc',
      channel: 'iap_ios',
      expiresInDays: 365,
    })
    const [subj, feat, body] = sdk.entitlementsV1.grants.create.mock.calls[0]
    expect(subj).toBe('s1')
    expect(feat).toBe('pnc')
    expect(body.amount).toBe(94_500_000)
    expect(Number.isInteger(body.amount)).toBe(true)
  })

  it('reportUsage ingests a cloudevent with integer micros in data', async () => {
    const sdk = fakeSdk()
    const om = createOmClient(sdk as any)
    await om.reportUsage('s1', 2700, { category: 'llm_tokens', dedupeId: 'evt_1' })
    const ev = sdk.events.ingest.mock.calls[0][0]
    expect(ev.subject).toBe('s1')
    expect(ev.type).toBe('pnc.usage')
    expect(ev.data.pnc_micros).toBe(2700)
    expect(ev.id).toBe('evt_1')
  })
})
