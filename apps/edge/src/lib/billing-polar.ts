// 入账/退款的影子账逻辑:edge 整数事实源(pnc_ledger)幂等 + 同步 Polar 钱包。
// Polar 是余额事实源;本表是 reconciliation 基准 + 供应商锁定/冻结的迁移底稿。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { PolarClient } from '../billing/polar-client'

export interface CreditInInput {
  subjectId: string
  kind: 'topup' | 'admin' | 'redemption'
  source: string
  externalRef: string
  pncMicros: number // 正数:发放额度
  markupSnapshot?: number
  raw?: unknown
}

export interface RefundInput {
  subjectId: string
  source: string
  externalRef: string
  pncMicros: number
  raw?: unknown
}

/** 当前可用额度(影子账 delta 累加;正=可用)。 */
export function availableMicros(rows: Array<{ delta_pnc_micros: number }>): number {
  return rows.reduce((s, r) => s + r.delta_pnc_micros, 0)
}

const UNIQUE_VIOLATION = '23505'

/** 入账:影子账幂等(unique(source,external_ref) 冲突=已处理过),仅新插入才推 Polar 发 credit。 */
export async function recordCreditIn(
  supa: SupabaseClient<any, any, any>,
  om: PolarClient,
  i: CreditInInput,
): Promise<{ applied: boolean }> {
  const micros = Math.abs(i.pncMicros)
  const { data, error } = await supa
    .from('pnc_ledger')
    .insert({
      subject_id: i.subjectId,
      kind: i.kind,
      source: i.source,
      external_ref: i.externalRef,
      delta_pnc_micros: micros,
      markup_snapshot: i.markupSnapshot ?? null,
      raw: i.raw ?? null,
    })
    .select('id')
    .maybeSingle()

  if (error) {
    if ((error as { code?: string }).code === UNIQUE_VIOLATION) return { applied: false }
    throw error
  }
  await om.grantCredits(i.subjectId, micros, {
    source: i.source,
    dedupeId: `${i.source}:${i.externalRef}`,
  })
  if (data?.id) await supa.from('pnc_ledger').update({ polar_synced: true }).eq('id', data.id)
  return { applied: true }
}

/** 退款:按影子账可用余额夹金额(不扣成负),写负向行 + Polar reduceCredits。 */
export async function recordRefund(
  supa: SupabaseClient<any, any, any>,
  om: PolarClient,
  i: RefundInput,
): Promise<{ applied: boolean; clampedMicros: number }> {
  const { data: rows } = await supa
    .from('pnc_ledger')
    .select('delta_pnc_micros')
    .eq('subject_id', i.subjectId)
  const available = availableMicros((rows ?? []) as Array<{ delta_pnc_micros: number }>)
  const clamped = Math.max(0, Math.min(Math.abs(i.pncMicros), available)) // 不扣成负;已耗部分不追讨

  const { error } = await supa
    .from('pnc_ledger')
    .insert({
      subject_id: i.subjectId,
      kind: 'refund',
      source: i.source,
      external_ref: i.externalRef,
      delta_pnc_micros: -clamped,
      raw: i.raw ?? null,
    })
    .select('id')
    .maybeSingle()
  if (error) {
    if ((error as { code?: string }).code === UNIQUE_VIOLATION) return { applied: false, clampedMicros: 0 }
    throw error
  }
  if (clamped > 0) {
    await om.reduceCredits(i.subjectId, clamped, {
      source: i.source,
      dedupeId: `refund:${i.source}:${i.externalRef}`,
    })
  }
  return { applied: true, clampedMicros: clamped }
}
