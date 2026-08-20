import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { requireSubjectAuth } from '../lib/device-grants';
import { getUserMemory } from '../lib/memory';
import { serviceClient, userClient } from '../lib/supabase';
import {
  redeemCode,
  RedemptionError,
} from '../lib/billing';
import { wallet } from '../billing/wallet-client';
import { resolveUserWalletSubjectId } from '../billing/subject-key';
import { grantSignupBonus, creditRedemptionToPolar } from '../lib/billing-grant';
import { billingEnabled } from '../lib/feature-flags';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import { randomToken, sha256Hex } from '../lib/device-grant-scopes';
import type { AppBindings } from '../types';

export const meRoutes = new Hono<AppBindings>();
meRoutes.use('/profile', requireSession());
meRoutes.use('/memory', requireSession());
meRoutes.use('/balance', requireSession());
meRoutes.use('/redeem', requireSession());
meRoutes.use('/billing/*', requireSession());
meRoutes.use('/subjects', requireSession());
meRoutes.use('/wallet/*', requireSession());
meRoutes.use('/account-deletion', requireSession());
meRoutes.use('/family-credential', requireSession());

function billingCategory(taskType: string, metadata: unknown): { key: string; label: string } {
  const source = metadata && typeof metadata === 'object'
    ? (metadata as Record<string, unknown>).source
    : null;
  if (taskType === 'message_reply') return { key: 'chat.reply', label: '聊天回复' };
  if (taskType === 'group_router') return { key: 'group.routing', label: '群聊路由' };
  if (taskType === 'voice_call') return { key: 'voice.call', label: '语音通话' };
  if (taskType === 'envelope' || taskType === 'scroll') return { key: 'envelope.write', label: '来信生成' };
  if (taskType === 'title') return { key: 'system.title', label: '自动标题' };
  if (taskType === 'lookback') return { key: 'memory.lookback', label: '记忆回看' };
  if (taskType === 'chat_memo') return { key: 'memory.memo', label: '聊天备忘' };
  if (taskType === 'bot_note') return { key: 'memory.bot_note', label: '机器人笔记' };
  if (taskType === 'tool' || source === 'web_tool') return { key: 'tool.web', label: '工具调用' };
  return { key: `other.${taskType || 'unknown'}`, label: taskType || '未知' };
}

// GET /v1/me/profile — read-side for app-wide user preferences. Today
// exposes notification_preview_mode (lock-screen privacy knob) and
// model_reveal_preference (global 模型盲盒 override); add other preference
// fields here as they appear rather than scattering them across the API.
// Backed by users.custom_fields so no schema migration is needed per knob —
// the iOS side is the source of truth for available modes (the union here
// just enforces server-side normalisation).
meRoutes.get('/profile', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa
    .from('users')
    .select('custom_fields')
    .eq('id', userId)
    .maybeSingle();
  if (error) {
    console.error('[me/profile] read failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  const cf = (data?.custom_fields ?? null) as Record<string, unknown> | null;
  const rawMode = cf?.notification_preview_mode;
  const mode =
    rawMode === 'name' || rawMode === 'name_content' ? rawMode : 'generic';
  // 全局模型盲盒档位。未设置 / 认不出的值一律归到 follow_bot(= 加这个开关
  // 之前的行为),客户端才不必自己防脏值。
  const rawReveal = cf?.model_reveal_preference;
  const revealPreference =
    rawReveal === 'always_real' || rawReveal === 'always_blind' ? rawReveal : 'follow_bot';
  // 新用户 welcome 赠送(35 PNC)——幂等 + best-effort,仅 BILLING_ENABLED 时种
  // Polar 余额。挂在 /profile(app 打开必经)上,免单独 signup 钩子。
  safeWaitUntil(c, grantSignupBonus(c.env, serviceClient(c.env), userId));
  return c.json({
    notification_preview_mode: mode,
    model_reveal_preference: revealPreference,
  });
});

// PATCH /v1/me/profile — write-side. Merges into users.custom_fields so
// other keys the iOS side may have stashed (avatar_seed etc.) survive.
// RLS policy users_self_update gates this to the caller's own row.
const PatchProfileBody = z.object({
  notification_preview_mode: z.enum(['generic', 'name', 'name_content']).optional(),
  model_reveal_preference: z.enum(['follow_bot', 'always_real', 'always_blind']).optional(),
});
// 每个偏好一个键(zod 键名 = custom_fields 键名)。列在这里是为了让"再加一个
// 偏好"只需要动两处:上面的 union + 这个数组。
const PROFILE_PREF_KEYS = ['notification_preview_mode', 'model_reveal_preference'] as const;
meRoutes.patch('/profile', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  let body: z.infer<typeof PatchProfileBody>;
  try {
    body = PatchProfileBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  // 只写请求里真正带了的键 —— 客户端每个 picker 只发自己那一格,没带的键保持
  // 库里的旧值。(以前这里是 `if (body.notification_preview_mode === undefined)
  // return`,加第二个字段后那句会把只带新字段的请求静默吞掉。)
  const present = PROFILE_PREF_KEYS.filter((k) => body[k] !== undefined);
  if (present.length === 0) {
    return c.json({ ok: true }); // nothing to patch
  }
  const supa = userClient(c.env, userJwt);
  const { data: existing } = await supa
    .from('users')
    .select('custom_fields')
    .eq('id', userId)
    .maybeSingle();
  const cf = ((existing?.custom_fields ?? {}) as Record<string, unknown>);
  for (const k of present) cf[k] = body[k];
  const { error } = await supa
    .from('users')
    .update({ custom_fields: cf as never })
    .eq('id', userId);
  if (error) {
    console.error('[me/profile] update failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  return c.json({ ok: true, ...Object.fromEntries(present.map((k) => [k, body[k]])) });
});

// POST /v1/me/account-deletion — 请求注销账号。SOT 写收进 worker(原客户端直连
// SupabaseStack.rpc),安全模型不变:request_account_deletion 内的 auth.uid() 守,
// userClient 带 user JWT → RLS/definer 上下文与原直连一致。(T2 #264)
// sentiment 必须是 request_account_deletion 函数白名单的两个值之一 —— 在边缘 zod
// 层挡住非法值返 400,而不是让 DB 函数 raise exception 冒成 500(runtime 验证发现)。
const RequestDeletionBody = z.object({
  sentiment: z.enum(['see_you_again', 'farewell_forever']),
});
meRoutes.post('/account-deletion', async (c) => {
  const userJwt = c.var.userJwt!;
  let body: z.infer<typeof RequestDeletionBody>;
  try {
    body = RequestDeletionBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const supa = userClient(c.env, userJwt);
  const { error } = await supa.rpc('request_account_deletion', { p_sentiment: body.sentiment });
  if (error) {
    console.error('[me/account-deletion] request failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  return c.json({ ok: true });
});

// DELETE /v1/me/account-deletion — 取消待注销(登录时调,清 tombstone)。
// 返回是否清掉了待删标记,客户端据此决定弹"已恢复账号"。
meRoutes.delete('/account-deletion', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('cancel_account_deletion');
  if (error) {
    console.error('[me/account-deletion] cancel failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  return c.json({ cleared: data === true });
});

// GET /v1/me/memory — transparency UI: "what bots see in me".
// Backed by KV (Honcho user-peer representation, refreshed after each turn).
// Per plan/02 this is the ONLY surface that exposes user representation —
// it's never injected into any bot's system prompt.
meRoutes.get('/memory', async (c) => {
  const userId = c.var.userId!;
  const memory = await getUserMemory(c.env, userId);
  if (!memory) {
    return c.json({ card: [], representation: '', syncedAt: null });
  }
  return c.json(memory);
});

// GET /v1/me/wallet/v2 — billing v2 wallet read.
// Returns total balance + active packs + recent ledger entries. RLS is
// the user's anon-key client, so they only see their own packs.
meRoutes.get('/wallet/v2', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);

  // 钱包与账本的主体键 = 该用户的 user_account subject id(**不是** auth user id):
  // pnc_ledger.subject_id 外键指向 subjects,入账只可能落在它上面。见
  // billing/subject-key.ts。解析不到就明确 404 —— 返回 0 余额会把"钱不见了"
  // 这件事伪装成"你没钱"。
  let subjectId: string;
  try {
    subjectId = await resolveUserWalletSubjectId(supa, userId);
  } catch (err) {
    console.error('[me/wallet/v2] wallet subject unresolved', userId, err);
    return jsonError(c, 404, 'subject_not_found', {
      message: '没有找到你的个人主体,请稍后重试',
    });
  }

  // 余额/阈值:WalletDO(Polar 缓存,强一致,计费 P2)—— 不再读 billing-v2 packs
  // 求和(packs 已退役,不再被扣减,会显示过期值)。账本明细:pnc_ledger(入账/退款
  // 审计;RLS 仅本人)。packs 字段保留为空数组以兼容旧客户端解码。
  const [gate, ledgerResult] = await Promise.all([
    wallet.gate(c.env, subjectId),
    supa
      .from('pnc_ledger')
      .select('id, kind, source, delta_pnc_micros, created_at')
      .eq('subject_id', subjectId)
      .order('created_at', { ascending: false })
      .limit(20),
  ]);

  return c.json({
    total_pnc_micros: gate.balanceMicros,
    threshold_state: gate.thresholdState,
    packs: [] as unknown[],
    recent_ledger: (ledgerResult.data ?? []).map((l) => ({
      id: l.id,
      pack_id: null,
      entry_type: l.kind,
      source: l.source,
      delta_pnc_micros: Number(l.delta_pnc_micros),
      balance_after_pnc_micros: null,
      created_at: l.created_at,
    })),
  });
});

// GET /v1/me/subject — personal responsibility subject + subject wallet
// compatibility read. Crew/temporary-group creation can use this as the
// bridge from the signed-in user to the billing/control subject without
// switching the existing wallet UI in one step.
meRoutes.get('/subject', requireSubjectAuth(['subject:read']), async (c) => {
  const isDeviceGrant = c.var.authKind === 'device_grant';
  const deviceGrant = c.var.deviceGrant;
  if (isDeviceGrant && !deviceGrant) return jsonError(c, 401, 'unauthorized');
  const supa = isDeviceGrant ? serviceClient(c.env) : userClient(c.env, c.var.userJwt!);

  let subjectQuery = supa
    .from('subjects')
    .select('id, kind, display_name, status, created_at, updated_at');
  subjectQuery = isDeviceGrant
    ? subjectQuery.eq('id', deviceGrant!.subjectId)
    : subjectQuery.eq('kind', 'user_account').eq('user_id', c.var.userId!);

  const { data: subject, error } = await subjectQuery.maybeSingle();

  if (error) {
    console.error('[me/subject] subject read failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  if (!subject) {
    return jsonError(c, 404, 'subject_not_found', {
      message: '个人责任主体尚未初始化',
    });
  }

  // 余额走 WalletDO(Polar 缓存,强一致;计费 P2)—— 与 /wallet/v2 同源。
  // 旧的 subject_wallets 表(billing-v1 快照,早已不被扣减)已退役(#226),
  // 不再读。`balance_credits` 现在是 PNC micros;lifetime_* 在新模型里不再
  // 按主体物化(账本明细见 pnc_ledger),保留字段为 0 以兼容旧解码。当前没有
  // 客户端解码本响应的 wallet 字段(iOS CrewSubjectEnvelope 只取 subject)。
  let balanceMicros = 0;
  try {
    ({ balanceMicros } = await wallet.gate(c.env, subject.id));
  } catch (err) {
    console.warn('[me/subject] wallet.gate failed, returning 0 balance', err);
  }
  // The PendingCrew (auth.users) user behind this call. For a device grant
  // that's grantedByUserId; for a user JWT it's the authenticated userId.
  // PendingCrew compares this against CrewWhiteboardEntry.senderUserId
  // (= messages.user_id = auth.users.id) to right-align the local user's
  // own crew-chat bubbles.
  const userId = isDeviceGrant ? (deviceGrant?.grantedByUserId ?? null) : (c.var.userId ?? null);
  // Wire shape keeps `subject_type`(= kind 的旧名): PendingCrew 的
  // listMySubjects() 显式按 CodingKeys `subject_type` 解码本响应
  // (apps/pendingcrew/Sources/Services/PendingCrewAPI.swift)。DB 列
  // subject_type 已切到 kind,这里从 kind 派生保持响应向后兼容。
  const { kind, ...subjectRest } = subject;
  return c.json({
    subject: { ...subjectRest, subject_type: kind },
    user_id: userId,
    wallet: {
      balance_credits: balanceMicros,
      lifetime_topup_credits: 0,
      lifetime_spent_credits: 0,
    },
  });
});

// GET /v1/me/subjects — every subject the caller can act on:
//   1. their personal user_account subject
//   2. group_account subjects where they are owner/admin (the only roles
//      allowed to "log in as the group" per spec v2 §4.3 — member can use
//      the group wallet for tasks but cannot mint a device-login grant for
//      it)
// Powers the iOS PendingBot "approve PendingCrew login → choose subject"
// picker.
meRoutes.get('/subjects', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  const supa = userClient(c.env, userJwt);

  // user_account subject — always exactly one row per user (subject_foundation
  // backfill + signup trigger guarantee it).
  const { data: personal, error: personalErr } = await supa
    .from('subjects')
    .select('id, kind, display_name, status')
    .eq('kind', 'user_account')
    .eq('user_id', userId)
    .eq('status', 'active')
    .maybeSingle();
  if (personalErr) {
    console.error('[me/subjects] personal read failed', personalErr);
    return jsonError(c, 500, 'internal_error');
  }

  // group_account subjects via group_subject_members. RLS on
  // group_subject_members already scopes membership to the calling user,
  // and the join into subjects exposes only those rows. Filter to
  // owner/admin here — the API contract is "subjects you can log in as",
  // not "subjects you can spend from".
  const { data: groupRows, error: groupErr } = await supa
    .from('group_subject_members')
    .select('role, subject:subjects!inner(id, kind, display_name, status)')
    .eq('user_id', userId)
    .in('role', ['owner', 'admin']);
  if (groupErr) {
    console.error('[me/subjects] group read failed', groupErr);
    return jsonError(c, 500, 'internal_error');
  }

  type SubjectListItem = {
    id: string;
    kind: 'user_account' | 'group_account';
    displayName: string;
    role?: 'owner' | 'admin';
  };
  const items: SubjectListItem[] = [];
  if (personal) {
    items.push({
      id: personal.id,
      kind: 'user_account',
      displayName: personal.display_name,
    });
  }
  for (const row of groupRows ?? []) {
    // PostgREST nested select returns either an object or an array
    // depending on FK cardinality; group_subject_members has a single FK
    // to subjects so the typed shape is an object, but be defensive.
    const subj = Array.isArray(row.subject) ? row.subject[0] : row.subject;
    if (!subj || subj.status !== 'active' || subj.kind !== 'group_account') continue;
    const role = row.role === 'owner' || row.role === 'admin' ? row.role : undefined;
    items.push({
      id: subj.id,
      kind: 'group_account',
      displayName: subj.display_name,
      role,
    });
  }

  return c.json({ subjects: items });
});

// POST /v1/me/family-credential — 登录态直接签发家族 SSO 凭据(pfa_*)。
// 与 device-login consume 路径(A3)互补:PendingBot Mac 自己登录后没有
// challenge/consume 这一拍,走这里拿凭据写进共享 keychain 组,供同 team
// 的 PendingCrew 调 POST /v1/device-grant/mint 静默换 scoped grant。
// RPC 是 insert-only(per-credential 行,90 天过期),重复调用 = 多发一张,
// 旧的留待过期/撤销 —— 与 consume 路径语义一致。返回形状对齐 device-login
// 的 familyCredential + subjectId(凭据绑定的默认 mint 目标 = 个人主体)。
const FamilyCredentialBody = z.object({
  deviceName: z.string().trim().min(1).max(120).default('Mac'),
});
meRoutes.post('/family-credential', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  let body: z.infer<typeof FamilyCredentialBody>;
  try {
    body = FamilyCredentialBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // 个人 user_account 主体 —— silent mint 的默认目标(同 /subjects 的读法)。
  const supa = userClient(c.env, userJwt);
  const { data: personal, error: subjectErr } = await supa
    .from('subjects')
    .select('id, display_name')
    .eq('kind', 'user_account')
    .eq('user_id', userId)
    .eq('status', 'active')
    .maybeSingle();
  if (subjectErr) {
    console.error('[me/family-credential] subject read failed', subjectErr);
    return jsonError(c, 500, 'internal_error');
  }
  if (!personal) {
    return jsonError(c, 404, 'subject_not_found', {
      message: '个人责任主体尚未初始化',
    });
  }

  // 头像 seed（users.custom_fields.avatar_seed，缺则回落 user id）——
  // PendingCrew 把它连同 displayName 存进共享 keychain 家族凭据，
  // 侧栏身份头像才能与 PendingBot 同字形。
  const { data: userRow } = await supa
    .from('users')
    .select('custom_fields')
    .eq('id', userId)
    .maybeSingle();
  const cf = (userRow?.custom_fields ?? null) as Record<string, unknown> | null;
  const avatarSeed = typeof cf?.avatar_seed === 'string' && cf.avatar_seed.length > 0
    ? cf.avatar_seed
    : userId;

  const token = randomToken('pfa');
  const svc = serviceClient(c.env);
  const { error: famErr } = await svc.rpc('issue_family_sso_credential', {
    p_id: crypto.randomUUID(),
    p_user_id: userId,
    p_token_hash: await sha256Hex(token),
    p_device_name: body.deviceName,
  });
  if (famErr) {
    console.error('[me/family-credential] issue rpc failed', famErr);
    return jsonError(c, 500, 'internal_error');
  }

  return c.json({
    familyCredential: { token, subjectId: personal.id },
    displayName: personal.display_name ?? null,
    avatarSeed,
  });
});

// POST /v1/me/redeem — trade a redemption code for credits. Atomic in
// the DB (billing_redeem RPC, FOR UPDATE + same-tx ledger insert);
// here we only translate error codes back to HTTP.
meRoutes.post('/redeem', async (c) => {
  const userJwt = c.var.userJwt!;
  let body: { code?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return jsonError(c, 400, 'invalid_body');
  }
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!code) {
    return jsonError(c, 400, 'invalid_body', { message: 'missing code' });
  }
  // 计费 kill-switch 关时(默认)不受理兑换 —— 否则会消耗掉码但无法入账(码白废)。
  // 先拒绝、绝不调 redeemCode(后者会原子标记 used)。
  if (!(await billingEnabled(c.env))) {
    return jsonError(c, 503, 'billing_disabled', { message: '兑换暂未开放' });
  }

  // billing_redeem reads auth.uid() — must use user-scoped client.
  const supa = userClient(c.env, userJwt);
  const userId = c.var.userId!;
  try {
    // RPC 原子校验+标记 used,返 {credits(PND), code_id};入账走 Polar
    // (ensureCustomer + grantCredits + 同步 WalletDO),不再碰旧钱包。
    const result = await redeemCode(supa, code);
    const creditedMicros = await creditRedemptionToPolar(
      c.env,
      serviceClient(c.env),
      userId,
      result.code_id,
      result.credits,
    );
    return c.json({
      ok: true,
      credits: result.credits, // PND 原值(兼容旧客户端展示)
      credited_pnc_micros: creditedMicros,
    });
  } catch (err) {
    if (err instanceof RedemptionError) {
      if (err.kind === 'not_authenticated') {
        return jsonError(c, 401, 'unauthorized', { message: err.message });
      }
      if (err.kind === 'not_found') {
        return jsonError(c, 400, 'redemption_not_found', { message: err.message });
      }
      if (err.kind === 'already_used') {
        return jsonError(c, 400, 'redemption_already_used', { message: err.message });
      }
      return jsonError(c, 400, 'internal_error', { message: err.message });
    }
    console.error('[me/redeem] unexpected', err);
    return jsonError(c, 500, 'internal_error');
  }
});

// GET /v1/me/billing/log?limit=50&before=<iso> — recent per-call
// charges for the iOS wallet's consumption list. Cursor pagination by
// `created_at` (descending). RLS scopes audit_log to the calling user
// (audit_log_self_read in 0033).
meRoutes.get('/billing/log', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);

  const limitParam = Number.parseInt(c.req.query('limit') ?? '', 10);
  const limit = Math.min(Math.max(Number.isFinite(limitParam) ? limitParam : 50, 1), 100);
  const before = c.req.query('before');

  let q = supa
    .from('audit_log')
    .select('id, created_at, task_type, model_id, cost_credits, billing_status, metadata')
    .in('billing_status', ['billed', 'unbilled'])
    .order('created_at', { ascending: false })
    .limit(limit);
  if (before) q = q.lt('created_at', before);

  const { data: rows, error } = await q;
  if (error) {
    console.error('[me/billing/log] query failed', error);
    return jsonError(c, 500, 'internal_error');
  }

  const turns = rows ?? [];

  const botIds = [
    ...new Set(
      turns
        .map((r) =>
          r.metadata && typeof r.metadata === 'object'
            ? ((r.metadata as Record<string, unknown>).bot_id as unknown)
            : null,
        )
        .filter((v): v is string => typeof v === 'string'),
    ),
  ];
  const { data: bots } = botIds.length
    ? await supa.from('bots').select('id, display_name').in('id', botIds)
    : { data: [] as { id: string; display_name: string }[] };
  const botName = new Map((bots ?? []).map((b) => [b.id, b.display_name]));

  const items = turns.map((r) => {
    const botId =
      r.metadata && typeof r.metadata === 'object'
        ? ((r.metadata as Record<string, unknown>).bot_id as unknown)
        : null;
    const category = billingCategory(r.task_type, r.metadata);
    return {
      id: r.id,
      created_at: r.created_at,
      task_type: r.task_type,
      category_key: category.key,
      category_label: category.label,
      model_id: r.model_id,
      cost_credits: Number(r.cost_credits) || 0,
      billing_status: r.billing_status,
      bot_id: typeof botId === 'string' ? botId : null,
      bot_name: typeof botId === 'string' ? botName.get(botId) ?? null : null,
    };
  });

  const nextCursor =
    items.length === limit ? items[items.length - 1].created_at : null;

  return c.json({ items, next_cursor: nextCursor });
});

// GET /v1/me/billing/summary?range=7d|30d|90d — aggregated spend for
// the iOS wallet's audit charts (the wallet no longer shows a per-call
// list; the detailed log lives in the board's /audit page). Breaks the
// caller's billed/unbilled spend (cost_credits — LLM + folded tool
// spend) down by day, model, task type and bot. RLS scopes audit_log
// to the calling user (audit_log_self_read in 0033); volume per user is
// small enough to aggregate in the worker rather than in SQL.
meRoutes.get('/billing/summary', async (c) => {
  const userJwt = c.var.userJwt!;
  const supa = userClient(c.env, userJwt);
  const rangeParam = c.req.query('range') ?? '30d';
  const days = rangeParam === '7d' ? 7 : rangeParam === '90d' ? 90 : 30;
  const since = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();

  const { data: rows } = await supa
    .from('audit_log')
    .select('created_at, task_type, model_id, cost_credits, metadata')
    .in('billing_status', ['billed', 'unbilled'])
    .gte('created_at', since)
    .limit(5000);

  let total = 0;
  const byDay = new Map<string, number>();
  const byModel = new Map<string, number>();
  const byTask = new Map<string, number>();
  const byCategory = new Map<string, { label: string; credits: number }>();
  const byBot = new Map<string, number>();
  for (const r of rows ?? []) {
    const credits = Number(r.cost_credits) || 0;
    total += credits;
    byDay.set(r.created_at.slice(0, 10), (byDay.get(r.created_at.slice(0, 10)) ?? 0) + credits);
    const model = r.model_id || '(未知)';
    byModel.set(model, (byModel.get(model) ?? 0) + credits);
    byTask.set(r.task_type, (byTask.get(r.task_type) ?? 0) + credits);
    const category = billingCategory(r.task_type, r.metadata);
    const existing = byCategory.get(category.key) ?? { label: category.label, credits: 0 };
    existing.credits += credits;
    byCategory.set(category.key, existing);
    const botId =
      r.metadata && typeof r.metadata === 'object'
        ? (r.metadata as Record<string, unknown>).bot_id
        : null;
    if (typeof botId === 'string') {
      byBot.set(botId, (byBot.get(botId) ?? 0) + credits);
    }
  }

  // Resolve bot display names so the chart shows names, not uuids.
  const botIds = [...byBot.keys()];
  const { data: bots } = botIds.length
    ? await supa.from('bots').select('id, display_name').in('id', botIds)
    : { data: [] as { id: string; display_name: string }[] };
  const botName = new Map((bots ?? []).map((b) => [b.id, b.display_name]));

  const ranked = (m: Map<string, number>) =>
    [...m.entries()]
      .map(([key, credits]) => ({ key, credits }))
      .sort((a, b) => b.credits - a.credits);

  return c.json({
    range_days: days,
    total_credits: total,
    by_day: [...byDay.entries()]
      .map(([day, credits]) => ({ day, credits }))
      .sort((a, b) => (a.day < b.day ? -1 : 1)),
    by_model: ranked(byModel),
    by_task: ranked(byTask),
    by_category: [...byCategory.entries()]
      .map(([key, v]) => ({ key, label: v.label, credits: v.credits }))
      .sort((a, b) => b.credits - a.credits),
    by_bot: ranked(byBot).map((e) => ({
      key: e.key,
      label: botName.get(e.key) ?? e.key.slice(0, 8),
      credits: e.credits,
    })),
  });
});
