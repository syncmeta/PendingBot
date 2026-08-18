// Worker → WalletDO 的薄封装。按 subjectId 路由到对应 DO,POST JSON RPC。
// WalletDO 见 src/durable-objects/wallet.ts;计费 P2。
import type { Env } from '../types';
import type { ThresholdState } from '../durable-objects/wallet';
import { billingEnabled } from '../lib/feature-flags';

export interface WalletResult {
  balanceMicros: number;
  thresholdState: ThresholdState;
}

function stub(env: Env, subjectId: string): DurableObjectStub {
  return env.WALLET.get(env.WALLET.idFromName(subjectId));
}

async function call(
  env: Env,
  subjectId: string,
  path: string,
  body: Record<string, unknown>,
): Promise<WalletResult> {
  const res = await stub(env, subjectId).fetch(`https://wallet.do/${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ subjectId, ...body }),
  });
  return (await res.json()) as WalletResult;
}

export interface DebitOpts {
  category: string; // llm_tokens / voice_tokens / web_tools / realtimekit_media / sandbox_runtime
  dedupeId: string; // 幂等键(audit id / turn id 等)
  meta?: Record<string, unknown>;
}

// 责任主体 → WalletDO 路由键。**路由键一律是 `pendingbot.subjects.id`**:
// 群 = responsible_subject_id,个人 = 该用户的 user_account subject id。
// credit/debit/gate 必须用同一键才会命中同一 DO,而入账侧被 pnc_ledger 的外键
// 钉死在 subjects.id,所以门禁/扣费侧只能对齐过来。
//
// 同步版的 `walletSubjectKey`(kind='user' 时直接返回 userId)已删:那是 2026-08-18
// 计费事故的根 —— 个人钱包被路由到 auth user id 那个永远空的 DO。要拿路由键请用
// `billing/subject-key.ts` 的 `resolveWalletSubjectKey`(异步,要查 subjects)。
export type WalletOwner =
  | { kind: 'user'; userId: string }
  | { kind: 'subject'; subjectId: string };

export const wallet = {
  /** 调用前门禁:读余额 + 阈值(不扣)。 */
  gate: (env: Env, subjectId: string): Promise<WalletResult> => call(env, subjectId, 'gate', {}),
  /** 扣费(幂等)。计费 kill-switch 关时(默认)直接 no-op:不扣、不向 Polar 上报用量。 */
  debit: async (env: Env, subjectId: string, pncMicros: number, opts: DebitOpts): Promise<WalletResult> => {
    if (!(await billingEnabled(env))) {
      return { balanceMicros: 0, thresholdState: 'sufficient' as ThresholdState };
    }
    return call(env, subjectId, 'debit', {
      pncMicros,
      category: opts.category,
      dedupeId: opts.dedupeId,
      meta: opts.meta ?? null,
    });
  },
  /** 充值/退款后同步缓存(Polar 侧已变)。pncMicros 可负(退款)。 */
  credit: (env: Env, subjectId: string, pncMicros: number): Promise<WalletResult> =>
    call(env, subjectId, 'credit', { pncMicros }),
  /** Polar customer.state_changed:对齐到绝对余额(DO 内减在途)。 */
  applyAbsolute: (env: Env, subjectId: string, polarBalanceMicros: number): Promise<WalletResult> =>
    call(env, subjectId, 'apply-absolute', { polarBalanceMicros }),
};
