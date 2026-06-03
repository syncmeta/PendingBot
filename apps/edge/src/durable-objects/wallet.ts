// WalletDO —— 每 subject 一个。Polar 是余额事实源;本 DO 是边缘的
// 强一致缓存 + 门禁闸 + 用量 outbox(计费 P2)。
// 设计/坑清单见 docs/superpowers/specs/2026-06-02-billing-p2-architecture-fork.md。
//
// 不是账本:只存一个 balance_micros + pending_usage 缓冲(待 flush 到 Polar)。
// - 门禁读本地(快、强一致);Polar ~10s 最终一致,只做 SoR/对账,不进热路径。
// - 充值/退款/Polar 侧变动 由 edge push 进来(credit / applyAbsolute)。
// - alarm 周期把 pending flush 给 Polar + 稀疏对账纠偏(防丢包)。
import { MICROS_PER_PNC } from '../billing/pnc';
import { polarFromEnv, type PolarClient } from '../billing/polar-client';
import { serviceClient } from '../lib/supabase';
import type { Env } from '../types';

// 阈值(micros)。来自 billing-v2-design §7.3:≥50 充足 / <50 提醒 / <5 节流 / ≤0 硬停。
const SUFFICIENT_MICROS = 50 * MICROS_PER_PNC;
const LOW_MICROS = 5 * MICROS_PER_PNC;
// overdraft buffer:允许扣到 −0.5 PNC(兜流式最后几 token 估算误差)。门禁在 ≤0 即硬停;
// debit 本身不拦(在途已发生),但跌破 floor 视为异常(记录,不再允许新调用)。
const OVERDRAFT_FLOOR_MICROS = -0.5 * MICROS_PER_PNC;

const FLUSH_DELAY_MS = 20_000; // debit 后多久批量 flush 到 Polar
const RECONCILE_MS = 5 * 60_000; // 稀疏对账间隔(防 webhook 丢包)
const GRACE_MS = 120_000; // 已 flush 行保留多久(> Polar 摄入延迟)再删

export type ThresholdState = 'sufficient' | 'low' | 'throttle' | 'exhausted';

export function thresholdOf(balanceMicros: number): ThresholdState {
  if (balanceMicros >= SUFFICIENT_MICROS) return 'sufficient';
  if (balanceMicros >= LOW_MICROS) return 'low';
  if (balanceMicros > 0) return 'throttle';
  return 'exhausted';
}

interface PendingRow {
  id: string;
  pnc_micros: number;
  category: string;
  flushed: number;
  flushed_at: number | null;
}

export class WalletDO {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.state.blockConcurrencyWhile(async () => {
      this.state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS pending_usage (
          id TEXT PRIMARY KEY,
          pnc_micros INTEGER NOT NULL,
          category TEXT NOT NULL,
          meta TEXT,
          created_at INTEGER NOT NULL,
          flushed INTEGER NOT NULL DEFAULT 0,
          flushed_at INTEGER
        );
      `);
    });
  }

  // ── 内部 helper ───────────────────────────────────────────────

  private async getBalance(): Promise<number> {
    return (await this.state.storage.get<number>('balance')) ?? 0;
  }
  private async setBalance(micros: number): Promise<void> {
    await this.state.storage.put('balance', micros);
  }

  private polar(): PolarClient | null {
    if (!this.env.POLAR_ACCESS_TOKEN || !this.env.POLAR_PNC_METER_ID) return null;
    return polarFromEnv(
      { POLAR_ACCESS_TOKEN: this.env.POLAR_ACCESS_TOKEN, POLAR_SERVER: this.env.POLAR_SERVER },
      this.env.POLAR_PNC_METER_ID,
    );
  }

  /** 惰性冷启动:首次触碰时记 subjectId + 从 Polar 拉初始余额。 */
  private async ensureInit(subjectId: string): Promise<void> {
    if (await this.state.storage.get<boolean>('initialized')) return;
    await this.state.storage.put('subjectId', subjectId);
    const om = this.polar();
    let initial = 0;
    if (om) {
      try {
        initial = await om.getBalance(subjectId);
      } catch (e) {
        console.warn('[WalletDO] init getBalance failed, start 0', (e as Error)?.message);
      }
    }
    await this.setBalance(initial);
    await this.state.storage.put('initialized', true);
    await this.state.storage.put('lastReconcileAt', Date.now());
  }

  private async subjectId(): Promise<string> {
    return (await this.state.storage.get<string>('subjectId')) ?? '';
  }

  /** 群池镜像漂移检查:group_pools.total 与 Polar 群余额偏差 > 1 PNC 报警(仅群 subject 有行)。 */
  private async checkGroupPoolDrift(subjectId: string, polarBalance: number): Promise<void> {
    try {
      const supa = serviceClient(this.env);
      const { data } = await supa
        .from('group_pools')
        .select('total_remaining_pnc_micros')
        .eq('subject_id', subjectId)
        .maybeSingle();
      if (!data) return; // 个人 subject 无群池行
      const mirror = Number(data.total_remaining_pnc_micros);
      if (Math.abs(mirror - polarBalance) > MICROS_PER_PNC) {
        console.warn(
          '[WalletDO] group_pool DRIFT',
          subjectId,
          'mirror=',
          mirror,
          'polar=',
          polarBalance,
        );
      }
    } catch (e) {
      console.warn('[WalletDO] group pool drift check failed', (e as Error)?.message);
    }
  }

  private pendingSumAll(): number {
    const row = this.state.storage.sql
      .exec<{ s: number | null }>('SELECT COALESCE(SUM(pnc_micros),0) AS s FROM pending_usage')
      .one();
    return Number(row.s ?? 0);
  }

  private async scheduleAlarm(delayMs: number): Promise<void> {
    const existing = await this.state.storage.getAlarm();
    if (existing == null) await this.state.storage.setAlarm(Date.now() + delayMs);
  }

  // ── RPC(fetch JSON)─────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
    const subjectId = String(body.subjectId ?? '');
    if (!subjectId) return Response.json({ error: 'missing subjectId' }, { status: 400 });

    switch (url.pathname) {
      case '/gate': {
        await this.ensureInit(subjectId);
        const balance = await this.getBalance();
        return Response.json({ thresholdState: thresholdOf(balance), balanceMicros: balance });
      }
      case '/debit': {
        await this.ensureInit(subjectId);
        const pnc = Math.max(0, Math.trunc(Number(body.pncMicros ?? 0)));
        const id = String(body.dedupeId ?? crypto.randomUUID());
        const category = String(body.category ?? 'unknown');
        // 幂等:同 id 已记则跳过(防重投/重试双扣)
        const dup = this.state.storage.sql
          .exec<{ c: number }>('SELECT COUNT(*) AS c FROM pending_usage WHERE id = ?', id)
          .one();
        if (Number(dup.c) === 0 && pnc > 0) {
          const balance = (await this.getBalance()) - pnc;
          await this.setBalance(balance);
          this.state.storage.sql.exec(
            'INSERT INTO pending_usage (id, pnc_micros, category, meta, created_at, flushed) VALUES (?,?,?,?,?,0)',
            id,
            pnc,
            category,
            JSON.stringify(body.meta ?? null),
            Date.now(),
          );
          await this.scheduleAlarm(FLUSH_DELAY_MS);
          if (balance < OVERDRAFT_FLOOR_MICROS) {
            console.warn('[WalletDO] balance below overdraft floor', subjectId, balance);
          }
        }
        const balance = await this.getBalance();
        return Response.json({ balanceMicros: balance, thresholdState: thresholdOf(balance) });
      }
      case '/credit': {
        // 充值/退款已在 Polar 侧完成(webhook),这里只同步缓存,不回推 Polar。
        await this.ensureInit(subjectId);
        const delta = Math.trunc(Number(body.pncMicros ?? 0)); // 退款可为负
        const balance = (await this.getBalance()) + delta;
        await this.setBalance(balance);
        return Response.json({ balanceMicros: balance, thresholdState: thresholdOf(balance) });
      }
      case '/apply-absolute': {
        // Polar customer.state_changed:对齐到 Polar 绝对值 − 在途 pending(防回环双扣,坑#1)。
        await this.ensureInit(subjectId);
        const polarBalance = Math.trunc(Number(body.polarBalanceMicros ?? 0));
        const balance = polarBalance - this.pendingSumAll();
        await this.setBalance(balance);
        await this.state.storage.put('lastReconcileAt', Date.now());
        return Response.json({ balanceMicros: balance, thresholdState: thresholdOf(balance) });
      }
      default:
        return Response.json({ error: 'not found' }, { status: 404 });
    }
  }

  // ── alarm:flush pending → Polar + 稀疏对账 + 清理 ─────────────

  async alarm(): Promise<void> {
    const om = this.polar();
    const subjectId = await this.subjectId();
    const now = Date.now();

    // 1) flush 未发的 pending → Polar.reportUsage(失败留着下轮重试)
    if (om && subjectId) {
      const unflushed = this.state.storage.sql
        .exec('SELECT * FROM pending_usage WHERE flushed = 0')
        .toArray() as unknown as PendingRow[];
      for (const row of unflushed) {
        try {
          await om.reportUsage(subjectId, row.pnc_micros, { category: row.category, dedupeId: row.id });
          this.state.storage.sql.exec(
            'UPDATE pending_usage SET flushed = 1, flushed_at = ? WHERE id = ?',
            now,
            row.id,
          );
        } catch (e) {
          console.warn('[WalletDO] flush failed, will retry', row.id, (e as Error)?.message);
        }
      }
    }

    // 2) 稀疏对账:保守地 balance = Polar 绝对值 − 所有在途(flushed+unflushed)→ 绝不高估(防超花)
    const lastReconcile = (await this.state.storage.get<number>('lastReconcileAt')) ?? 0;
    if (om && subjectId && now - lastReconcile > RECONCILE_MS) {
      try {
        const polarBalance = await om.getBalance(subjectId);
        await this.setBalance(polarBalance - this.pendingSumAll());
        await this.state.storage.put('lastReconcileAt', now);
        // 群池漂移报警(计费 P2 群钱包):group_pools.total 是公平性镜像,应与 Polar
        // 群余额一致;偏差 > 1 PNC 报警(不自动改写,避免与 share_index 失配)。仅群 subject 有行。
        await this.checkGroupPoolDrift(subjectId, polarBalance);
      } catch (e) {
        console.warn('[WalletDO] reconcile failed', (e as Error)?.message);
      }
    }

    // 3) 清理:已 flush 且超过 grace(Polar 已反映)的行删掉
    this.state.storage.sql.exec(
      'DELETE FROM pending_usage WHERE flushed = 1 AND flushed_at IS NOT NULL AND flushed_at < ?',
      now - GRACE_MS,
    );

    // 4) 还有未发的 → 继续排 alarm;否则按对账周期再排一次
    const remaining = this.state.storage.sql
      .exec<{ c: number }>('SELECT COUNT(*) AS c FROM pending_usage WHERE flushed = 0')
      .one();
    if (Number(remaining.c) > 0) {
      await this.state.storage.setAlarm(now + FLUSH_DELAY_MS);
    } else {
      await this.state.storage.setAlarm(now + RECONCILE_MS);
    }
  }
}
