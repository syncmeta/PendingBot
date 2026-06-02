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

describe('polar-client', () => {
  it('exposes the fixed pnc event name + metadata key', () => {
    expect(PNC_EVENT_NAME).toBe('pnc.usage')
    expect(PNC_METADATA_KEY).toBe('pnc')
  })

  it('reportUsage ingests an event keyed by externalCustomerId with pnc in metadata', async () => {
    const sdk = fakeSdk()
    const om = createPolarClient(sdk as any, { meterId: 'meter_pnc' })
    await om.reportUsage('subject_1', 2700, { category: 'llm_tokens' })
    const req = sdk.events.ingest.mock.calls[0][0]
    const ev = req.events[0]
    expect(ev.name).toBe('pnc.usage')
    expect(ev.externalCustomerId).toBe('subject_1')
    expect(ev.metadata.pnc).toBe(2700)
    expect(ev.metadata.category).toBe('llm_tokens')
  })

  it('getBalance returns the matching meter balance from customer state', async () => {
    const om = createPolarClient(fakeSdk(94_497_300) as any, { meterId: 'meter_pnc' })
    expect(await om.getBalance('subject_1')).toBe(94_497_300)
  })

  it('getBalance returns 0 when our meter is absent', async () => {
    const sdk = {
      events: { ingest: vi.fn() },
      customers: { getStateExternal: vi.fn().mockResolvedValue({ activeMeters: [] }) },
    }
    const om = createPolarClient(sdk as any, { meterId: 'meter_pnc' })
    expect(await om.getBalance('subject_1')).toBe(0)
  })
})
