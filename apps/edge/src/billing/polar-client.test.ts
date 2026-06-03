import { describe, expect, it, vi } from 'vitest'
import { createPolarClient, PNC_EVENT_NAME, PNC_METADATA_KEY } from './polar-client'

function fakeSdk(balance = 94_497_300) {
  return {
    events: { ingest: vi.fn().mockResolvedValue(undefined) },
    customers: {
      getStateExternal: vi
        .fn()
        .mockResolvedValue({ activeMeters: [{ meterId: 'meter_pnc', balance }] }),
    },
  }
}

const cli = (sdk: unknown) => createPolarClient(sdk as any, { meterId: 'meter_pnc' })

describe('polar-client', () => {
  it('exposes the fixed pnc event name + metadata key', () => {
    expect(PNC_EVENT_NAME).toBe('pnc.usage')
    expect(PNC_METADATA_KEY).toBe('pnc')
  })

  it('reportUsage ingests a POSITIVE event keyed by externalCustomerId + dedupe external_id', async () => {
    const sdk = fakeSdk()
    await cli(sdk).reportUsage('subject_1', 2700, { category: 'llm_tokens', dedupeId: 'evt_1' })
    const ev = sdk.events.ingest.mock.calls[0][0].events[0]
    expect(ev.name).toBe('pnc.usage')
    expect(ev.externalCustomerId).toBe('subject_1')
    expect(ev.externalId).toBe('evt_1') // Polar 去重键
    expect(ev.metadata.pnc).toBe(2700) // 正值 = 扣费
    expect(ev.metadata.category).toBe('llm_tokens')
  })

  it('grantCredits ingests a NEGATIVE event with dedupe id (official grant mechanism)', async () => {
    const sdk = fakeSdk()
    await cli(sdk).grantCredits('subject_1', 94_500_000, { source: 'iap_ios', dedupeId: 'txn_abc' })
    const ev = sdk.events.ingest.mock.calls[0][0].events[0]
    expect(ev.externalCustomerId).toBe('subject_1')
    expect(ev.externalId).toBe('txn_abc')
    expect(ev.metadata.pnc).toBe(-94_500_000) // 负值 = 发放 credit
    expect(ev.metadata.kind).toBe('grant')
    expect(ev.metadata.source).toBe('iap_ios')
  })

  it('reduceCredits ingests a POSITIVE refund event (caller must clamp amount)', async () => {
    const sdk = fakeSdk()
    await cli(sdk).reduceCredits('subject_1', 1000, { source: 'apple_refund', dedupeId: 'rf_1' })
    const ev = sdk.events.ingest.mock.calls[0][0].events[0]
    expect(ev.metadata.pnc).toBe(1000)
    expect(ev.metadata.kind).toBe('refund')
    expect(ev.externalId).toBe('rf_1')
  })

  it('getBalance returns the matching meter balance (positive = available)', async () => {
    expect(await cli(fakeSdk(94_497_300)).getBalance('subject_1')).toBe(94_497_300)
  })

  it('getBalance returns 0 when our meter is absent', async () => {
    const sdk = {
      events: { ingest: vi.fn() },
      customers: { getStateExternal: vi.fn().mockResolvedValue({ activeMeters: [] }) },
    }
    expect(await cli(sdk).getBalance('subject_1')).toBe(0)
  })

  it('ensureCustomer creates the customer with externalId + email', async () => {
    const create = vi.fn().mockResolvedValue({ id: 'cus_1' })
    const sdk = { events: { ingest: vi.fn() }, customers: { getStateExternal: vi.fn(), create } }
    await cli(sdk).ensureCustomer('subject_1', 'u@example.com')
    expect(create).toHaveBeenCalledWith({ email: 'u@example.com', externalId: 'subject_1' })
  })

  it('ensureCustomer swallows a 409 (already exists) as idempotent success', async () => {
    const create = vi.fn().mockRejectedValue({ statusCode: 409, message: 'customer already exists' })
    const sdk = { events: { ingest: vi.fn() }, customers: { getStateExternal: vi.fn(), create } }
    await expect(cli(sdk).ensureCustomer('subject_1', 'u@example.com')).resolves.toBeUndefined()
  })

  it('ensureCustomer rethrows non-conflict errors (e.g. 500)', async () => {
    const create = vi.fn().mockRejectedValue({ statusCode: 500, message: 'server error' })
    const sdk = { events: { ingest: vi.fn() }, customers: { getStateExternal: vi.fn(), create } }
    await expect(cli(sdk).ensureCustomer('subject_1', 'u@example.com')).rejects.toMatchObject({
      statusCode: 500,
    })
  })
})
