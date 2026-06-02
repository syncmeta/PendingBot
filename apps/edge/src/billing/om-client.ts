// OpenMeter 薄封装。只暴露 PendingBot 计费需要的领域操作。
// 真实 SDK：@openmeter/sdk 的 entitlementsV1(subject 维度，subject = 用户/群账号)。
// 见 docs/superpowers/specs/2026-06-01-billing-engine-design.md。
import { OpenMeter } from '@openmeter/sdk'

export const PNC_FEATURE_KEY = 'pnc'
export const PNC_METER_SLUG = 'pnc'
/** 上报扣费用的事件 type；pnc meter 以此 eventType 聚合。 */
export const PNC_USAGE_EVENT_TYPE = 'pnc.usage'

/** grant 幂等：用 渠道+外部交易id 拼确定性 grant id，重投不重复加额度。 */
export function grantIdFor(channel: string, externalPurchaseId: string): string {
  return `pnc_${channel}_${externalPurchaseId}`
}

// 我们只用 SDK 的这三块；用结构化类型避免与 SDK 内部类型强耦合。
type Sdk = {
  subjects: { upsert: (subjects: unknown) => Promise<unknown> }
  entitlementsV1: {
    create: (subjectKey: string, body: unknown) => Promise<unknown>
    value: (subjectKey: string, featureKey: string, query?: unknown) => Promise<unknown>
    grants: {
      create: (subjectKey: string, featureKey: string, body: unknown) => Promise<unknown>
      void: (entitlementId: string, grantId: string) => Promise<unknown>
    }
  }
  events: { ingest: (events: unknown) => Promise<unknown> }
}

export interface GrantOpts {
  externalId: string
  channel: string
  expiresInDays?: number // 标准充值包 365；不传=永不过期(长期包)
  priority?: number // 1..255；默认靠 expiration 让最快过期先燃
}

export interface UsageOpts {
  category: string // llm_tokens / voice_tokens / ...（spec §5 八类）
  dedupeId: string // CloudEvents id，去重
  metadata?: Record<string, unknown>
}

export function createOmClient(sdk: Sdk) {
  return {
    /** 确保 subject 存在(用户/群账号)。key = 我们的 subject_id。 */
    async ensureSubject(subjectKey: string): Promise<void> {
      await sdk.subjects.upsert([{ key: subjectKey }])
    },

    /** 为 subject 建 metered PNC entitlement(软上限,grant 驱动余额,无周期 reset)。 */
    async ensureEntitlement(subjectKey: string): Promise<unknown> {
      return sdk.entitlementsV1.create(subjectKey, {
        type: 'metered',
        featureKey: PNC_FEATURE_KEY,
        isSoftLimit: true,
        issueAfterReset: 0,
      })
    },

    /** 充值/赠送：发一笔 credit grant(整数 micros)。 */
    async grantCredits(
      subjectKey: string,
      amountMicros: number,
      opts: GrantOpts,
    ): Promise<unknown> {
      const body: Record<string, unknown> = {
        amount: amountMicros,
        priority: opts.priority ?? 100,
        effectiveAt: new Date().toISOString(),
        metadata: { channel: opts.channel, externalId: opts.externalId },
      }
      if (opts.expiresInDays != null) {
        body.expiration = { duration: 'DAY', count: opts.expiresInDays }
      }
      return sdk.entitlementsV1.grants.create(subjectKey, PNC_FEATURE_KEY, body)
    },

    /** 扣费：上报一条 usage event(整数 micros)。 */
    async reportUsage(subjectKey: string, amountMicros: number, opts: UsageOpts): Promise<void> {
      await sdk.events.ingest({
        id: opts.dedupeId,
        type: PNC_USAGE_EVENT_TYPE,
        subject: subjectKey,
        time: new Date().toISOString(),
        data: { pnc_micros: amountMicros, category: opts.category, ...(opts.metadata ?? {}) },
      })
    },

    /** 门禁读余额：返回整数 micros。 */
    async getBalance(subjectKey: string): Promise<number> {
      const v = (await sdk.entitlementsV1.value(subjectKey, PNC_FEATURE_KEY)) as {
        balance?: number
      }
      return Math.trunc(v.balance ?? 0)
    },

    /** 退款冲销：void 指定 grant 的剩余额度。 */
    async voidGrant(entitlementId: string, grantId: string): Promise<void> {
      await sdk.entitlementsV1.grants.void(entitlementId, grantId)
    },
  }
}

export type OmClient = ReturnType<typeof createOmClient>

/** 用 Env 构造真实 SDK 的 client。 */
export function omFromEnv(env: { OPENMETER_API_KEY: string; OPENMETER_BASE_URL: string }): OmClient {
  const sdk = new OpenMeter({ baseUrl: env.OPENMETER_BASE_URL, apiKey: env.OPENMETER_API_KEY })
  return createOmClient(sdk as unknown as Sdk)
}
