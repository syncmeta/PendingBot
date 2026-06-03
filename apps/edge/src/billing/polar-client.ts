// Polar 薄封装。只暴露 PendingBot 计费需要的领域操作。
// 真实 SDK：@polar-sh/sdk。Customer 以 externalId = 我们的 subject_id 标识。
// 见 docs/superpowers/specs/2026-06-01-billing-engine-design.md。
//
// 符号约定(统一"全事件"模型，避免 Polar 双约定坑)：
//   meter = SUM(metadata.pnc)；**扣费/退款 = 正值；充值/发 credit = 负值**。
//   不挂 Credits Benefit(它走 credited−consumed 正向，与负值事件混用不自洽)。
//   web 购买与 iOS IAP 都经 webhook 走 grantCredits(负值)入账。
//   getStateExternal 的 balance(=credited−consumed，此模型下 credited=0)→ 正数=可用额度。
//   确切符号 + 余额刷新延迟由 P0 spike 实跑确认。
import { Polar } from '@polar-sh/sdk'

/** 上报事件名；Polar meter 配置为按 metadata.pnc 求和。 */
export const PNC_EVENT_NAME = 'pnc.usage'
/** meter 聚合的 metadata 数值字段名。 */
export const PNC_METADATA_KEY = 'pnc'

// 只用 SDK 的这两块；结构化类型避免与 SDK 内部类型强耦合(真实形状由 spike 锁定)。
// events.ingest 的 externalId 是 Polar 的去重键(重复 external_id 被跳过)。
type Sdk = {
  events: {
    ingest: (req: {
      events: Array<{
        name: string
        externalId?: string
        externalCustomerId?: string
        metadata?: Record<string, unknown>
      }>
    }) => Promise<unknown>
  }
  customers: {
    getStateExternal: (req: {
      externalId: string
    }) => Promise<{ activeMeters?: Array<{ meterId: string; balance: number }> }>
    // CustomerCreate(individual):email 必填,externalId 可选(SDK @0.47.1 验证)。
    create: (req: {
      email: string
      externalId?: string
      metadata?: Record<string, unknown>
    }) => Promise<{ id: string }>
  }
}

export interface UsageOpts {
  category: string // llm_tokens / voice_tokens / ...（spec §5 八类）
  dedupeId: string // Polar event external_id，防 outbox/webhook 重投重复计
  metadata?: Record<string, unknown>
}

export interface GrantOpts {
  source: string // iap_ios / polar_checkout / admin / redemption ...
  dedupeId: string // 上游交易 id(RC event.id / transaction_id / order id)，幂等键
}

export function createPolarClient(sdk: Sdk, opts: { meterId: string }) {
  return {
    /** 扣费：上报正值 usage event。dedupeId 防重投。 */
    async reportUsage(externalCustomerId: string, pnc: number, u: UsageOpts): Promise<void> {
      await sdk.events.ingest({
        events: [
          {
            name: PNC_EVENT_NAME,
            externalId: u.dedupeId,
            externalCustomerId,
            metadata: { [PNC_METADATA_KEY]: Math.abs(pnc), category: u.category, ...(u.metadata ?? {}) },
          },
        ],
      })
    },

    /** 充值/发 credit：上报负值事件(无需 checkout，web+iOS 入账都走这里)。dedupeId 幂等。 */
    async grantCredits(externalCustomerId: string, pnc: number, g: GrantOpts): Promise<void> {
      await sdk.events.ingest({
        events: [
          {
            name: PNC_EVENT_NAME,
            externalId: g.dedupeId,
            externalCustomerId,
            metadata: { [PNC_METADATA_KEY]: -Math.abs(pnc), kind: 'grant', source: g.source },
          },
        ],
      })
    },

    /**
     * 退款冲减:上报正值事件(与扣费同向)减少可用额度。
     * ⚠️ Polar 不会把余额夹在 0；退款 3-case 的"不扣成负/已耗不追讨"必须调用方先夹好金额。
     */
    async reduceCredits(externalCustomerId: string, pnc: number, g: GrantOpts): Promise<void> {
      await sdk.events.ingest({
        events: [
          {
            name: PNC_EVENT_NAME,
            externalId: g.dedupeId,
            externalCustomerId,
            metadata: { [PNC_METADATA_KEY]: Math.abs(pnc), kind: 'refund', source: g.source },
          },
        ],
      })
    },

    /**
     * 幂等确保 Polar customer 存在(externalId = 我们的 subjectId)。
     * 送(signup)/兑换给"从没付过钱"的用户发额度的前置:这类用户没经过
     * checkout,Polar 里没有 customer,而 grantCredits 需要一个 customer。
     * customers.create 的 email 必填(SDK 验证)。已存在(409)吞掉作幂等成功;
     * 其余错误抛出。⚠️ 409 的确切判定 + 是否需 ensure 由 sandbox spike 实测确认。
     */
    async ensureCustomer(externalId: string, email: string): Promise<void> {
      try {
        await sdk.customers.create({ email, externalId })
      } catch (e) {
        const err = e as { statusCode?: number; status?: number; message?: string }
        const status = err?.statusCode ?? err?.status
        const dup = status === 409 || /already.*exist|exists/i.test(err?.message ?? '')
        if (dup) return // 已存在 → 幂等成功
        throw e
      }
    },

    /** 门禁读余额：从 customer state 取我们 meter 的余额(正=可用;找不到记 0)。 */
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
