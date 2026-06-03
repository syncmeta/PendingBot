// T1.2 — Group account permission matrix HTTP layer (spec v2 §4.3 α).
//
// Mounts under /v1/group-subjects/.
//
// All endpoints require a user-session (supabase JWT). Device-grant tokens
// are intentionally NOT accepted here — grants represent a *runner host*
// acting on behalf of an already-elected subject, not a person managing
// the subject's membership/permissions. The grp_* RPCs key off
// auth.uid() (see migration 20260528083639), so we forward the user JWT
// via userClient.
//
// Routes:
//
//   POST   /v1/group-subjects                       — create a new group
//                                                     account; caller auto-
//                                                     owner. body { display_name }
//                                                     → { subject_id }
//
//   GET    /v1/group-subjects/:id/members           — list members the caller
//                                                     can see (RLS-scoped).
//                                                     → { members: [...] }
//
//   POST   /v1/group-subjects/:id/members           — add a member.
//                                                     owner|admin only.
//                                                     body { user_id }
//
//   DELETE /v1/group-subjects/:id/members/:userId   — remove member.
//                                                     owner|admin; can't kick
//                                                     owner; admin removal
//                                                     requires owner.
//
//   POST   /v1/group-subjects/:id/members/:userId/promote
//                                                   — promote member→admin.
//                                                     owner only.
//
//   POST   /v1/group-subjects/:id/members/:userId/demote
//                                                   — demote admin→member.
//                                                     owner only.
//
//   POST   /v1/group-subjects/:id/transfer          — transfer ownership.
//                                                     owner only. target must
//                                                     already be a member.
//                                                     body { to_user_id }
//
//   POST   /v1/group-subjects/:id/topup             — recharge the subject
//                                                     wallet. owner|admin|member
//                                                     (spec v2 §4.3: 充值全员开放).
//                                                     body { credits }
//                                                     → { balance_credits }
//
// **No withdrawal endpoint** (spec v2 §4.3: 无提现 — 规避「金融服务」性质合规
// 风险, 简化产品). Don't add one without explicit product sign-off.
//
// Authorization is enforced server-side by the SECURITY DEFINER grp_* RPCs
// (see migration 20260528083639_group_account_permission_rpcs.sql). We
// translate the RPC's PostgreSQL error codes into the typed jsonError
// envelope here — never duplicate the role-check logic in the route.

import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient, type SupabaseClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings, Env } from '../types';
import { polarFromEnv, type PolarClient } from '../billing/polar-client';
import { contributeToGroup, refundContributorFromGroup, dissolveGroup, setPledge, withdrawFromGroup, readGroupWallet, type MemberWalletView } from '../billing/group-wallet';
import { pncToMicros, pncMicrosToPnc } from '../billing/pnc';

// 群钱包 = Polar(余额事实源)+ WalletDO 缓存(计费 P2)。注资/退款/解散走
// billing/group-wallet.ts(service-role 内部记账 + Polar 转账 + share-index)。
function polarOrNull(env: Env): PolarClient | null {
  if (!env.POLAR_ACCESS_TOKEN || !env.POLAR_PNC_METER_ID) return null;
  return polarFromEnv(
    { POLAR_ACCESS_TOKEN: env.POLAR_ACCESS_TOKEN, POLAR_SERVER: env.POLAR_SERVER },
    env.POLAR_PNC_METER_ID,
  );
}

export const groupSubjectRoutes = new Hono<AppBindings>();
groupSubjectRoutes.use('/*', requireSession());

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function isUuid(s: string): boolean {
  return UUID_RE.test(s);
}

type RpcError = { message: string; code?: string };

// Translate a PostgreSQL ERRCODE raised by a grp_* RPC into our typed HTTP
// envelope. The RPCs use a small, deliberate set of SQLSTATEs:
//   42501 → forbidden (role check failed)
//   28000 → unauthorized (auth.uid() was NULL — JWT not forwarded)
//   P0002 → not_found (subject/target missing)
//   22023 → invalid_state (e.g. "target is owner", non-positive credits)
// Anything else is surfaced as database_error so we don't silently swallow
// unexpected failures.
function rpcErrorToResponse(
  c: Parameters<typeof jsonError>[0],
  err: RpcError,
): Response {
  const code = err.code ?? '';
  const message = err.message ?? 'database error';

  switch (code) {
    case '42501':
      return jsonError(c, 403, 'subject_forbidden', { message });
    case '28000':
      return jsonError(c, 401, 'unauthorized', { message });
    case 'P0002':
      return jsonError(c, 404, 'subject_not_found', { message });
    case '22023':
      return jsonError(c, 409, 'conflict', { message });
    default:
      return jsonError(c, 500, 'database_error', { detail: { code, message } });
  }
}

function clientForRequest(c: Parameters<typeof jsonError>[0]): SupabaseClient | Response {
  const jwt = c.var.userJwt;
  if (!jwt) return jsonError(c, 401, 'unauthorized');
  return userClient(c.env, jwt);
}

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects — create
// ────────────────────────────────────────────────────────────────────

const CreateBody = z.object({
  display_name: z.string().trim().min(1).max(80),
});

groupSubjectRoutes.post('/', async (c) => {
  let body: z.infer<typeof CreateBody>;
  try {
    body = CreateBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { data, error } = await supa.rpc('grp_create_group_subject', {
    p_display_name: body.display_name,
  });
  if (error) return rpcErrorToResponse(c, error);
  if (typeof data !== 'string') {
    return jsonError(c, 500, 'internal_error', { message: 'rpc returned non-uuid' });
  }
  return c.json({ subject_id: data }, 201);
});

// ────────────────────────────────────────────────────────────────────
// GET /v1/group-subjects/:id/members — list (RLS-scoped read)
// ────────────────────────────────────────────────────────────────────
//
// RLS on group_subject_members already restricts which rows the caller
// sees: members see their own row; owner/admin see all rows in the
// subject (group_subject_members_admin_read policy). That means a
// `member` caller gets a 1-row list — fine for "am I a member?" checks
// and avoids leaking the roster. We do not hide existence of the
// subject — if the caller has no membership row, the list is simply
// empty + we surface 404 to distinguish "subject doesn't exist" from
// "you have no membership row".

groupSubjectRoutes.get('/:id/members', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id', { message: 'id must be a uuid' });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  // Confirm the subject exists (and is a group_account). RLS on subjects
  // allows the caller to see any subject they have access to via
  // group_subject_members; non-members get null.
  const { data: subject, error: subjErr } = await supa
    .from('subjects')
    .select('id, kind, status')
    .eq('id', id)
    .maybeSingle();
  if (subjErr) return jsonError(c, 500, 'database_error', { detail: subjErr.message });
  if (!subject || subject.kind !== 'group_account') {
    return jsonError(c, 404, 'subject_not_found');
  }

  const { data: rows, error } = await supa
    .from('group_subject_members')
    .select('user_id, role, granted_by, granted_at')
    .eq('subject_id', id);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ members: rows ?? [] });
});

// ────────────────────────────────────────────────────────────────────
// GET /v1/group-subjects/:id/wallet — 群钱包视图(读)
// ────────────────────────────────────────────────────────────────────
//
// 实缴池余额 + S(分摊分母)+ 我的实缴 share_now/认缴/总份额/占比 + 成员明细。
// owner/admin 看全员明细(members_complete=true);member 仅看自己(只读 WalletDO+
// DB,跨成员读用 service client,但可见范围按角色裁剪,与 /members 的 RLS 语义一致)。
// 金额一律 PNC(micros 不出网,与 /topup 等动作端点的 *_pnc 口径一致)。
// 读不动钱,不要求 Polar 配置(余额取自 WalletDO 缓存)。

groupSubjectRoutes.get('/:id/wallet', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) return jsonError(c, 400, 'invalid_id');
  const userId = c.var.userId;
  if (!userId) return jsonError(c, 401, 'unauthorized');

  // 成员校验(RLS 读自己的 membership 行)。
  const rls = clientForRequest(c);
  if (rls instanceof Response) return rls;
  const { data: membership } = await rls
    .from('group_subject_members')
    .select('role')
    .eq('subject_id', id)
    .eq('user_id', userId)
    .maybeSingle();
  if (!membership) return jsonError(c, 403, 'subject_forbidden', { message: '非群成员' });

  const view = await readGroupWallet(c.env, serviceClient(c.env), id);

  const canSeeAll = membership.role === 'owner' || membership.role === 'admin';
  const ratio = (stake: number) => (view.totalStakeMicros > 0 ? stake / view.totalStakeMicros : 0);
  const mapMember = (m: MemberWalletView) => ({
    user_id: m.userId,
    contribution_share_now_pnc: pncMicrosToPnc(m.contributionShareNowMicros),
    pledge_pnc: pncMicrosToPnc(m.pledgeMicros),
    pledge_effective_pnc: pncMicrosToPnc(m.pledgeEffectiveMicros),
    stake_pnc: pncMicrosToPnc(m.stakeMicros),
    share_ratio: ratio(m.stakeMicros),
  });

  const mine: MemberWalletView = view.members.find((m) => m.userId === userId) ?? {
    userId,
    contributionShareNowMicros: 0,
    pledgeMicros: 0,
    pledgeEffectiveMicros: 0,
    stakeMicros: 0,
  };

  return c.json({
    subject_id: id,
    role: membership.role,
    pool_pnc: pncMicrosToPnc(view.poolMicros),
    total_stake_pnc: pncMicrosToPnc(view.totalStakeMicros),
    me: mapMember(mine),
    members: canSeeAll ? view.members.map(mapMember) : [mapMember(mine)],
    members_complete: canSeeAll,
  });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/members — add member
// ────────────────────────────────────────────────────────────────────

const AddMemberBody = z.object({
  user_id: z.string().uuid(),
});

groupSubjectRoutes.post('/:id/members', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id', { message: 'id must be a uuid' });
  }
  let body: z.infer<typeof AddMemberBody>;
  try {
    body = AddMemberBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_add_member', {
    p_group_subject_id: id,
    p_user_id: body.user_id,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// DELETE /v1/group-subjects/:id/members/:userId — remove member
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.delete('/:id/members/:userId', async (c) => {
  const id = c.req.param('id');
  const userId = c.req.param('userId');
  if (!isUuid(id) || !isUuid(userId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_remove_member', {
    p_group_subject_id: id,
    p_user_id: userId,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/members/:userId/promote — owner only
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.post('/:id/members/:userId/promote', async (c) => {
  const id = c.req.param('id');
  const userId = c.req.param('userId');
  if (!isUuid(id) || !isUuid(userId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_promote_to_admin', {
    p_group_subject_id: id,
    p_user_id: userId,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/members/:userId/demote — owner only
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.post('/:id/members/:userId/demote', async (c) => {
  const id = c.req.param('id');
  const userId = c.req.param('userId');
  if (!isUuid(id) || !isUuid(userId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_demote_admin', {
    p_group_subject_id: id,
    p_user_id: userId,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/transfer — owner only
// ────────────────────────────────────────────────────────────────────

const TransferBody = z.object({
  to_user_id: z.string().uuid(),
});

groupSubjectRoutes.post('/:id/transfer', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id');
  }
  let body: z.infer<typeof TransferBody>;
  try {
    body = TransferBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = clientForRequest(c);
  if (supa instanceof Response) return supa;

  const { error } = await supa.rpc('grp_transfer_ownership', {
    p_group_subject_id: id,
    p_to_user_id: body.to_user_id,
  });
  if (error) return rpcErrorToResponse(c, error);
  return c.json({ ok: true });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/topup — owner|admin|member (spec v2 §4.3)
// ────────────────────────────────────────────────────────────────────
//
// This is the *accounting* hook — real-money flows (IAP / billing
// webhook) happen out-of-band and the webhook handler calls the same
// RPC under service_role. Exposing it to authenticated callers preserves
// the "self-serve topup" UX path for the future.

const TopupBody = z.object({
  credits: z.number().int().positive(),
});

groupSubjectRoutes.post('/:id/topup', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) {
    return jsonError(c, 400, 'invalid_id');
  }
  let body: z.infer<typeof TopupBody>;
  try {
    body = TopupBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const userId = c.var.userId;
  if (!userId) return jsonError(c, 401, 'unauthorized');

  // 成员校验:走 RLS 读自己的 membership 行(非成员看不到 → 拒)。
  const rls = clientForRequest(c);
  if (rls instanceof Response) return rls;
  const { data: membership } = await rls
    .from('group_subject_members')
    .select('role')
    .eq('subject_id', id)
    .eq('user_id', userId)
    .maybeSingle();
  if (!membership) return jsonError(c, 403, 'subject_forbidden', { message: '非群成员' });

  const om = polarOrNull(c.env);
  if (!om) return jsonError(c, 501, 'polar_not_configured');

  // 注资:从出资人 Polar 钱包转入群 Polar 钱包 + 记 share-index 贡献。
  const r = await contributeToGroup({
    env: c.env,
    supa: serviceClient(c.env),
    om,
    subjectId: id,
    contributorUserId: userId,
    pncMicros: pncToMicros(body.credits),
  });
  if (!r.ok) {
    if (r.reason === 'insufficient_balance') return jsonError(c, 402, 'quota_exceeded', { message: '余额不足' });
    if (r.reason === 'invalid_amount') return jsonError(c, 400, 'invalid_body');
    return jsonError(c, 500, 'database_error', { message: r.message });
  }
  return c.json({ ok: true, contribution_id: r.contributionId, contributed_pnc: pncMicrosToPnc(r.debitedMicros) });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/leave — 退出群:按 share-index 退回我的份额
// ────────────────────────────────────────────────────────────────────
//
// 把调用者在群里的当前份额(share_now)退回其个人钱包、标记其 contributions
// refunded,清其认缴,并移除其成员行(一步退群)。群主不能直接退群(须先转让或解散)。

groupSubjectRoutes.post('/:id/leave', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) return jsonError(c, 400, 'invalid_id');
  const userId = c.var.userId;
  if (!userId) return jsonError(c, 401, 'unauthorized');

  const rls = clientForRequest(c);
  if (rls instanceof Response) return rls;
  const { data: membership } = await rls
    .from('group_subject_members')
    .select('role')
    .eq('subject_id', id)
    .eq('user_id', userId)
    .maybeSingle();
  if (!membership) return jsonError(c, 403, 'subject_forbidden', { message: '非群成员' });
  if (membership.role === 'owner') {
    return jsonError(c, 409, 'conflict', { message: '群主需先转让群主或解散群,不能直接退群' });
  }

  const om = polarOrNull(c.env);
  if (!om) return jsonError(c, 501, 'polar_not_configured');

  const supa = serviceClient(c.env);
  // 1. 退份额(no_contributions 视作退 0,仍继续退群)。
  const r = await refundContributorFromGroup({ env: c.env, supa, om, subjectId: id, contributorUserId: userId });
  const refundedMicros = r.ok ? r.refundedMicros : 0;
  const contributionsRefunded = r.ok ? r.contributionsRefunded : 0;
  if (!r.ok && r.reason !== 'no_contributions' && r.reason !== 'pool_missing') {
    return jsonError(c, 500, 'database_error', { message: r.message });
  }
  // 2. 清认缴授权(撤销该群对其钱包的扣款授权)。
  await setPledge(supa, id, userId, 0);
  // 3. 移除成员行(自退;grp_remove_member 仅 owner/admin 可删人,故 service 直删)。
  await supa.from('group_subject_members').delete().eq('subject_id', id).eq('user_id', userId);

  return c.json({
    ok: true,
    refunded_pnc: pncMicrosToPnc(refundedMicros),
    contributions_refunded: contributionsRefunded,
  });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/dissolve — 解散群:按比例退所有 active 出资人
// owner only。
// ────────────────────────────────────────────────────────────────────

groupSubjectRoutes.post('/:id/dissolve', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) return jsonError(c, 400, 'invalid_id');
  const userId = c.var.userId;
  if (!userId) return jsonError(c, 401, 'unauthorized');

  const rls = clientForRequest(c);
  if (rls instanceof Response) return rls;
  const { data: membership } = await rls
    .from('group_subject_members')
    .select('role')
    .eq('subject_id', id)
    .eq('user_id', userId)
    .maybeSingle();
  if (membership?.role !== 'owner') return jsonError(c, 403, 'subject_forbidden', { message: '仅群主可解散' });

  const om = polarOrNull(c.env);
  if (!om) return jsonError(c, 501, 'polar_not_configured');

  const r = await dissolveGroup({ env: c.env, supa: serviceClient(c.env), om, subjectId: id });
  return c.json({
    ok: true,
    refunded_contributors: r.refundedContributors,
    total_refunded_pnc: pncMicrosToPnc(r.totalRefundedMicros),
  });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/pledge — 设置/清除认缴额度(钱不动,授权群按比例扣)
// body { credits }(PNC;0 = 撤销认缴)。成员均可。
// ────────────────────────────────────────────────────────────────────

const PledgeBody = z.object({ credits: z.number().int().min(0) });

groupSubjectRoutes.post('/:id/pledge', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) return jsonError(c, 400, 'invalid_id');
  const userId = c.var.userId;
  if (!userId) return jsonError(c, 401, 'unauthorized');
  let body: z.infer<typeof PledgeBody>;
  try {
    body = PledgeBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const rls = clientForRequest(c);
  if (rls instanceof Response) return rls;
  const { data: membership } = await rls
    .from('group_subject_members')
    .select('role')
    .eq('subject_id', id)
    .eq('user_id', userId)
    .maybeSingle();
  if (!membership) return jsonError(c, 403, 'subject_forbidden', { message: '非群成员' });

  await setPledge(serviceClient(c.env), id, userId, pncToMicros(body.credits));
  return c.json({ ok: true, pledge_pnc: body.credits });
});

// ────────────────────────────────────────────────────────────────────
// POST /v1/group-subjects/:id/withdraw — 部分取出(≤ 当前 share_now),留群
// body { credits }(PNC)。退回个人 PNC 余额(非提现)。
// ────────────────────────────────────────────────────────────────────

const WithdrawBody = z.object({ credits: z.number().int().positive() });

groupSubjectRoutes.post('/:id/withdraw', async (c) => {
  const id = c.req.param('id');
  if (!isUuid(id)) return jsonError(c, 400, 'invalid_id');
  const userId = c.var.userId;
  if (!userId) return jsonError(c, 401, 'unauthorized');
  let body: z.infer<typeof WithdrawBody>;
  try {
    body = WithdrawBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const rls = clientForRequest(c);
  if (rls instanceof Response) return rls;
  const { data: membership } = await rls
    .from('group_subject_members')
    .select('role')
    .eq('subject_id', id)
    .eq('user_id', userId)
    .maybeSingle();
  if (!membership) return jsonError(c, 403, 'subject_forbidden', { message: '非群成员' });

  const om = polarOrNull(c.env);
  if (!om) return jsonError(c, 501, 'polar_not_configured');

  const r = await withdrawFromGroup({
    env: c.env,
    supa: serviceClient(c.env),
    om,
    subjectId: id,
    userId,
    amountMicros: pncToMicros(body.credits),
  });
  return c.json({ ok: true, withdrawn_pnc: pncMicrosToPnc(r.withdrawnMicros) });
});
