// apps/edge/src/routes/board-billing.ts
//
// Board 计费管理端点。挂在 boardRoutes 之下,继承 Cloudflare Access 门
// (requireCfAccess + requireBoardAdmin) —— 与 board-model-roles 同样的授权模式。
//
//   GET  /v1/board/billing/packs           → 两组销售通道的 product_id→PNC 映射
//                                            (KV 覆盖 + 代码默认,逐 product 合成)
//   PUT  /v1/board/billing/packs           → 写 cfg:billing-packs KV 覆盖 + 审计
//   GET  /v1/board/billing/wallet?q=…      → 按 user id / email 查余额 + 最近账本(只读)
//   POST /v1/board/billing/grant           → 直接发/扣额度(admin grant / claw-back)
//
// 套餐映射:board 是运行时改 product_id→PNC 的唯一入口(见 lib/billing-packs.ts
// 的两源合成)。ASC / Polar 建好真实商品后在这里填映射即生效,不用改代码发版。
//
// grant/claw-back:走与 webhook 相同的活路径 —— recordCreditIn/recordRefund
// (kind='admin', source='admin') 写 pnc_ledger + 同步 WalletDO。刻意不调
// 旧的 billing_admin_grant RPC:那个写的是已退役的 v1 topups/billing_credit
// 表,和用户真正看到的 WalletDO 余额脱钩(会「发了额度但钱包不动」)。
import { Hono } from 'hono';
import { z } from 'zod';
import { jsonError } from '../lib/http-error';
import { serviceClient } from '../lib/supabase';
import { recordBoardAudit } from '../lib/board-audit';
import {
  BILLING_PACKS_KV_KEY,
  BILLING_PACK_DEFAULTS,
  PACK_SOURCES,
  type PackOverrides,
  type PackSource,
  type PncPack,
} from '../lib/billing-packs';
import { recordCreditIn, recordRefund } from '../lib/billing-polar';
import { polarFromEnv } from '../billing/polar-client';
import { wallet } from '../billing/wallet-client';
import { findUserWalletSubjectId } from '../billing/subject-key';
import { pncToMicros } from '../billing/pnc';
import type { AppBindings, Env } from '../types';

export const boardBillingRoutes = new Hono<AppBindings>();

async function readOverrides(env: Env): Promise<PackOverrides> {
  try {
    return (await env.MEMORY.get<PackOverrides>(BILLING_PACKS_KV_KEY, 'json')) ?? {};
  } catch {
    return {};
  }
}

function polar(env: Env) {
  return polarFromEnv(
    { POLAR_ACCESS_TOKEN: env.POLAR_ACCESS_TOKEN as string, POLAR_SERVER: env.POLAR_SERVER },
    env.POLAR_PNC_METER_ID as string,
  );
}

// ── 套餐映射 ────────────────────────────────────────────────────────────

// GET: 每个通道回 { defaults, overrides, effective },effective = override ?? default
// 逐 product 合成(与 resolvePack 同口径)。
boardBillingRoutes.get('/packs', async (c) => {
  const ov = await readOverrides(c.env);
  const data: Record<
    PackSource,
    {
      defaults: Record<string, PncPack>;
      overrides: Record<string, PncPack>;
      effective: Record<string, PncPack>;
    }
  > = {} as never;
  for (const source of PACK_SOURCES) {
    const defaults = BILLING_PACK_DEFAULTS[source] ?? {};
    const overrides = ov[source] ?? {};
    data[source] = { defaults, overrides, effective: { ...defaults, ...overrides } };
  }
  return c.json({ data });
});

// PUT body: 每个通道 → { [productId]: PncPack | null }。
//   PncPack 值 = 设/改覆盖;null = 清除该 product 的覆盖(回退代码默认或消失);
//   通道省略 = 该通道不变。
const PackSchema = z.object({
  pnc: z.number().int().positive(),
  markupSnapshot: z.number().positive(),
});
const PutPacksBody = z.record(
  z.enum(PACK_SOURCES as unknown as [PackSource, ...PackSource[]]),
  z.record(z.string().min(1), PackSchema.nullable()).optional(),
);

boardBillingRoutes.put('/packs', async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = PutPacksBody.safeParse(body);
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });

  const before = await readOverrides(c.env);
  const next: PackOverrides = JSON.parse(JSON.stringify(before));
  for (const source of PACK_SOURCES) {
    const patch = parsed.data[source];
    if (patch === undefined) continue; // 通道省略 = 不变
    const cur = { ...(next[source] ?? {}) };
    for (const [productId, val] of Object.entries(patch)) {
      if (val === null) delete cur[productId];
      else cur[productId] = val;
    }
    if (Object.keys(cur).length > 0) next[source] = cur;
    else delete next[source];
  }
  try {
    await c.env.MEMORY.put(BILLING_PACKS_KV_KEY, JSON.stringify(next));
  } catch (err) {
    return jsonError(c, 500, 'database_error', { detail: String(err) });
  }
  await recordBoardAudit(c, {
    action: 'update',
    targetKind: 'billing_packs',
    targetId: BILLING_PACKS_KV_KEY,
    before,
    after: next,
  });
  return c.json({ data: next });
});

// ── 钱包查询(只读) ──────────────────────────────────────────────────────

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * 按 q(user id UUID 或 email)解析出这个人 —— 同时给出 **auth user id**(展示/审计用)
 * 和 **个人钱包主体键 subjectId**(= user_account subject id,钱包/账本/Polar 都用它)。
 * 两者是不同的 uuid:`pnc_ledger.subject_id` 外键指向 subjects,拿 users.id 当 subject
 * 写会直接违反外键;查余额拿 users.id 也只会读到一个空 WalletDO。
 * 查无此人 → null;查到人但没有 user_account 主体 → { subjectId: null },由路由 404。
 */
async function resolveUserId(
  supa: ReturnType<typeof serviceClient>,
  q: string,
): Promise<{ userId: string; email: string | null; subjectId: string | null } | null> {
  const query = supa.from('users').select('id, email');
  const { data } = UUID_RE.test(q)
    ? await query.eq('id', q).maybeSingle()
    : await query.eq('email', q.trim().toLowerCase()).maybeSingle();
  const row = data as { id?: string; email?: string | null } | null;
  if (!row?.id) return null;
  return {
    userId: row.id,
    email: row.email ?? null,
    subjectId: await findUserWalletSubjectId(supa, row.id),
  };
}

/** 查到人但没有个人主体:明确 404 + 日志,绝不退化成"余额 0 / 发到 user id 上"。 */
function noSubject(hit: { userId: string }): void {
  console.error('[board/billing] wallet subject unresolved', hit.userId);
}

boardBillingRoutes.get('/wallet', async (c) => {
  const q = (c.req.query('q') ?? '').trim();
  if (!q) return jsonError(c, 400, 'invalid_body', { message: '需要 q(user id 或 email)' });

  const supa = serviceClient(c.env);
  const hit = await resolveUserId(supa, q);
  if (!hit) return jsonError(c, 404, 'not_found', { message: '查无此用户' });
  if (!hit.subjectId) {
    noSubject(hit);
    return jsonError(c, 404, 'subject_not_found', { message: '该用户没有个人主体(user_account subject)' });
  }

  let balanceMicros = 0;
  let thresholdState = 'unknown';
  try {
    const gate = await wallet.gate(c.env, hit.subjectId);
    balanceMicros = gate.balanceMicros;
    thresholdState = gate.thresholdState;
  } catch (err) {
    console.warn('[board/billing/wallet] wallet.gate failed', err);
  }

  const { data: ledger } = await supa
    .from('pnc_ledger')
    .select('id, kind, source, external_ref, delta_pnc_micros, created_at')
    .eq('subject_id', hit.subjectId)
    .order('created_at', { ascending: false })
    .limit(30);

  return c.json({
    data: {
      user_id: hit.userId,
      email: hit.email,
      balance_pnc_micros: balanceMicros,
      threshold_state: thresholdState,
      recent_ledger: (ledger ?? []).map((l) => ({
        id: l.id,
        kind: l.kind,
        source: l.source,
        external_ref: l.external_ref,
        delta_pnc_micros: Number(l.delta_pnc_micros),
        created_at: l.created_at,
      })),
    },
  });
});

// ── grant / claw-back ────────────────────────────────────────────────────

const GrantBody = z.object({
  q: z.string().min(1), // user id 或 email
  pnc: z.number().int().refine((n) => n !== 0, 'pnc 不能为 0'), // 正=发放 负=收回
  reason: z.string().min(1).max(500),
});

boardBillingRoutes.post('/grant', async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = GrantBody.safeParse(body);
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });
  const { q, pnc, reason } = parsed.data;

  const supa = serviceClient(c.env);
  const hit = await resolveUserId(supa, q);
  if (!hit) return jsonError(c, 404, 'not_found', { message: '查无此用户' });
  if (!hit.subjectId) {
    noSubject(hit);
    return jsonError(c, 404, 'subject_not_found', { message: '该用户没有个人主体(user_account subject),无法发放' });
  }
  const subjectId = hit.subjectId;

  if (!c.env.POLAR_ACCESS_TOKEN || !c.env.POLAR_PNC_METER_ID) {
    return jsonError(c, 501, 'polar_not_configured', {
      message: 'Polar 未配置,无法发放/收回额度',
    });
  }
  const om = polar(c.env);
  // 幂等键:board 手动操作用时间戳,允许对同一用户多次 grant。
  const externalRef = `board:${Date.now()}`;
  const micros = pncToMicros(Math.abs(pnc));

  try {
    if (pnc > 0) {
      const { applied } = await recordCreditIn(supa, om, {
        subjectId,
        kind: 'admin',
        source: 'admin',
        externalRef,
        pncMicros: micros,
        raw: { reason, actor: c.var.boardEmail ?? null },
      });
      if (applied) await wallet.credit(c.env, subjectId, micros).catch(() => undefined);
    } else {
      const { clampedMicros } = await recordRefund(supa, om, {
        subjectId,
        source: 'admin',
        externalRef,
        pncMicros: micros,
        raw: { reason, actor: c.var.boardEmail ?? null },
      });
      if (clampedMicros > 0) await wallet.credit(c.env, subjectId, -clampedMicros).catch(() => undefined);
    }
  } catch (err) {
    return jsonError(c, 500, 'database_error', { detail: String(err) });
  }

  await recordBoardAudit(c, {
    action: 'update',
    targetKind: pnc > 0 ? 'billing_grant' : 'billing_clawback',
    targetId: hit.userId,
    before: null,
    after: { pnc, reason },
  });
  return c.json({ data: { ok: true, user_id: hit.userId, pnc } });
});
