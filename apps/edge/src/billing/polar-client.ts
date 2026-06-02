// Polar 薄封装。只暴露 PendingBot 计费需要的领域操作。
// 真实 SDK：@polar-sh/sdk。Customer 以 externalId = 我们的 subject_id 标识。
// 见 docs/superpowers/specs/2026-06-01-billing-engine-design.md。
import { Polar } from '@polar-sh/sdk'

/** 上报扣费的事件名；Polar meter 配置为按 metadata 里的 pnc 字段求和。 */
export const PNC_EVENT_NAME = 'pnc.usage'
/** meter 聚合的 metadata 数值字段名。 */
export const PNC_METADATA_KEY = 'pnc'

// 只用 SDK 的这两块；结构化类型避免与 SDK 内部类型强耦合(真实形状由 spike 锁定)。
type Sdk = {
  events: {
    ingest: (req: {
      events: Array<{
        name: string
        externalCustomerId?: string
        metadata?: Record<string, unknown>
      }>
    }) => Promise<unknown>
  }
  customers: {
    getStateExternal: (req: {
      externalId: string
    }) => Promise<{ activeMeters?: Array<{ meterId: string; balance: number }> }>
  }
}

export interface UsageOpts {
  category: string // llm_tokens / voice_tokens / ...（spec §5 八类）
  metadata?: Record<string, unknown>
}

// 符号约定(Polar 官方《Grant Meter Credits Before Purchase》)：
// meter = SUM(metadata.pnc)。**扣费 = 正值;充值/发 credit = 负值**。
// 可用额度 = -(meter 余额)(负余额代表可用)。确切符号 + getStateExternal.balance 语义由 P0 spike 锁定。
export function createPolarClient(sdk: Sdk, opts: { meterId: string }) {
  return {
    /** 扣费：上报正值 usage event(externalCustomerId = subject_id)。 */
    async reportUsage(externalCustomerId: string, pnc: number, u: UsageOpts): Promise<void> {
      await sdk.events.ingest({
        events: [
          {
            name: PNC_EVENT_NAME,
            externalCustomerId,
            metadata: { [PNC_METADATA_KEY]: pnc, category: u.category, ...(u.metadata ?? {}) },
          },
        ],
      })
    },

    /** 充值/发 credit：上报负值事件(官方机制,无需 checkout,iOS IAP 入账走这里)。 */
    async grantCredits(
      externalCustomerId: string,
      pnc: number,
      meta: { source: string; externalId: string },
    ): Promise<void> {
      await sdk.events.ingest({
        events: [
          {
            name: PNC_EVENT_NAME,
            externalCustomerId,
            metadata: {
              [PNC_METADATA_KEY]: -Math.abs(pnc), // 负值 = 发放 credit
              kind: 'grant',
              source: meta.source, // iap_ios / lemon_squeezy 已弃 / polar_checkout / admin ...
              externalId: meta.externalId, // 幂等去重靠上游(provider 交易 id)
            },
          },
        ],
      })
    },

    /** 门禁读余额：从 customer state 取我们 meter 的余额(找不到记 0)。 */
    async getBalance(externalCustomerId: string): Promise<number> {
      const state = await sdk.customers.getStateExternal({ externalId: externalCustomerId })
      const m = (state.activeMeters ?? []).find((x) => x.meterId === opts.meterId)
      return m ? m.balance : 0
    },
  }
}

export type PolarClient = ReturnType<typeof createPolarClient>

/** 用 Env 构造真实 SDK 的 client。meterId 来自 bootstrap 时创建的 pnc meter。 */
export function polarFromEnv(
  env: { POLAR_ACCESS_TOKEN: string; POLAR_SERVER?: string },
  meterId: string,
): PolarClient {
  const sdk = new Polar({
    accessToken: env.POLAR_ACCESS_TOKEN,
    server: (env.POLAR_SERVER as 'sandbox' | 'production' | undefined) ?? 'production',
  })
  return createPolarClient(sdk as unknown as Sdk, { meterId })
}
