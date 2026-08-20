import { describe, expect, it } from 'vitest'
import { resolveRcSubjectId, type RcSubjectLookup } from './billing-webhooks'

/** mock:user_id 命中表 + subject_id 命中表,记录查询走向。 */
function mockLookup(opts: { byUser?: Record<string, string>; bySubject?: Record<string, string> }): RcSubjectLookup {
  return {
    from: () => ({
      select: () => ({
        eq: (col: string, v: string) => ({
          // 双 eq 链 = user_id + kind 查询
          eq: () => ({
            maybeSingle: async () => ({ data: opts.byUser?.[v] ? { id: opts.byUser[v] } : null }),
          }),
          // 单 eq 链 = subject id 直查兜底
          maybeSingle: async () => ({ data: opts.bySubject?.[v] ? { id: opts.bySubject[v] } : null }),
        }),
      }),
    }),
  }
}

describe('resolveRcSubjectId', () => {
  it('auth user id 经 subjects.user_id 映射到 user_account subject', async () => {
    const supa = mockLookup({ byUser: { 'auth-uid-1': 'subject-1' } })
    expect(await resolveRcSubjectId(supa, 'auth-uid-1')).toBe('subject-1')
  })

  it('映射不到时按 subject id 直用兜底', async () => {
    const supa = mockLookup({ bySubject: { 'subject-2': 'subject-2' } })
    expect(await resolveRcSubjectId(supa, 'subject-2')).toBe('subject-2')
  })

  it('两边都查不到 → undefined(webhook skipped,不写错账)', async () => {
    const supa = mockLookup({})
    expect(await resolveRcSubjectId(supa, 'nonexistent')).toBeUndefined()
  })

  it('RC 匿名 id / 空值 / 非字符串直接放弃,不打 DB', async () => {
    const supa: RcSubjectLookup = {
      from: () => {
        throw new Error('should not query')
      },
    }
    expect(await resolveRcSubjectId(supa, '$RCAnonymousID:abc')).toBeUndefined()
    expect(await resolveRcSubjectId(supa, '')).toBeUndefined()
    expect(await resolveRcSubjectId(supa, undefined)).toBeUndefined()
    expect(await resolveRcSubjectId(supa, 123)).toBeUndefined()
  })
})
