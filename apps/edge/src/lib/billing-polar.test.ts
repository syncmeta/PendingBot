import { describe, expect, it, vi } from 'vitest'
import { recordCreditIn, recordRefund, availableMicros } from './billing-polar'

// 极简 supabase mock：insert(...).select(...).maybeSingle() + select(...).eq(...)
function fakeSupa(opts: { insertErr?: { code: string } | null; rows?: Array<{ delta_pnc_micros: number }> } = {}) {
  const update = vi.fn().mockReturnValue({ eq: vi.fn().mockResolvedValue({ error: null }) })
  return {
    _update: update,
    from: vi.fn().mockReturnValue({
      insert: vi.fn().mockReturnValue({
        select: vi.fn().mockReturnValue({
          maybeSingle: vi
            .fn()
            .mockResolvedValue({ data: opts.insertErr ? null : { id: 'led_1' }, error: opts.insertErr ?? null }),
        }),
      }),
      select: vi.fn().mockReturnValue({
        eq: vi.fn().mockResolvedValue({ data: opts.rows ?? [], error: null }),
      }),
      update,
    }),
  }
}

describe('billing-polar', () => {
  it('availableMicros sums ledger deltas', () => {
    expect(availableMicros([{ delta_pnc_micros: 270_000_000 }, { delta_pnc_micros: -700 }])).toBe(269_999_300)
  })

  it('recordCreditIn writes ledger + grants on first delivery', async () => {
    const supa = fakeSupa()
    const om = { grantCredits: vi.fn().mockResolvedValue(undefined), reduceCredits: vi.fn() }
    const r = await recordCreditIn(supa as any, om as any, {
      subjectId: 's1', kind: 'topup', source: 'iap_ios', externalRef: 'txn_1', pncMicros: 270_000_000,
    })
    expect(r.applied).toBe(true)
    expect(om.grantCredits).toHaveBeenCalledTimes(1)
    const [subj, micros, g] = om.grantCredits.mock.calls[0]
    expect(subj).toBe('s1')
    expect(micros).toBe(270_000_000)
    expect(g.dedupeId).toBe('iap_ios:txn_1')
  })

  it('recordCreditIn is idempotent on unique violation (no double grant)', async () => {
    const supa = fakeSupa({ insertErr: { code: '23505' } })
    const om = { grantCredits: vi.fn(), reduceCredits: vi.fn() }
    const r = await recordCreditIn(supa as any, om as any, {
      subjectId: 's1', kind: 'topup', source: 'iap_ios', externalRef: 'txn_1', pncMicros: 270_000_000,
    })
    expect(r.applied).toBe(false)
    expect(om.grantCredits).not.toHaveBeenCalled()
  })

  it('recordRefund clamps to available balance (never claws to negative)', async () => {
    const supa = fakeSupa({ rows: [{ delta_pnc_micros: 1000 }] }) // 只剩 1000 可用
    const om = { grantCredits: vi.fn(), reduceCredits: vi.fn().mockResolvedValue(undefined) }
    const r = await recordRefund(supa as any, om as any, {
      subjectId: 's1', source: 'iap_ios', externalRef: 'txn_1:refund', pncMicros: 270_000_000, // 想退 270M
    })
    expect(r.clampedMicros).toBe(1000) // 夹到可用
    expect(om.reduceCredits).toHaveBeenCalledTimes(1)
    expect(om.reduceCredits.mock.calls[0][1]).toBe(1000)
  })

  it('recordRefund with zero available does not call reduceCredits', async () => {
    const supa = fakeSupa({ rows: [] })
    const om = { grantCredits: vi.fn(), reduceCredits: vi.fn() }
    const r = await recordRefund(supa as any, om as any, {
      subjectId: 's1', source: 'iap_ios', externalRef: 'x:refund', pncMicros: 5000,
    })
    expect(r.clampedMicros).toBe(0)
    expect(om.reduceCredits).not.toHaveBeenCalled()
  })
})
