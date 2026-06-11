import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { generateInitialBotDescription } from '../lib/group-bot-intro';
import { rateLimitOrBlock } from '../lib/rate-limit';
import { jsonError } from '../lib/http-error';
import { isGroupHumanParticipant, requireGroupRole } from '../lib/route-authz';
import { trackEvent, AnalyticsEvent } from '../lib/track';
import type { AppBindings } from '../types';

// All group endpoints sit under /v1/groups. Schema + RPCs live in
// supabase/migrations/0043 + 0044. Most handlers are thin RPC wrappers:
// the SECURITY DEFINER functions own role checks and invariants, the
// edge owns request shape, JSON, and translating Postgres exceptions
// to HTTP errors.
//
// Auth: every route requires a session. Worker calls go through
// userClient(env, jwt) so auth.uid() resolves inside the RPC. Lookups
// that don't need auth.uid() (e.g. resolving a join handle) use
// serviceClient instead, since they may need to read across the
// membership graph.

export const groupRoutes = new Hono<AppBindings>();
groupRoutes.use('*', requireSession());

// Convert a postgres error from supabase-js into a structured HTTP
// response. We surface the message verbatim — RPC error messages are
// human-readable Chinese/English by design.
//
// supabase-js .rpc() returns the postgres error as a plain object
// (`{ code, message, details, hint }`) — `PostgrestError` is only
// constructed when the caller opted into `.throwOnError()`. So we
// can't rely on `instanceof Error`; pull `.message` off the object.
// Without this, every well-known RPC exception fell through to the
// "database" 500 branch (e.g. a QR scan that resolved to a user QR
// rather than a group surfaced as "database error" instead of 404,
// blocking iOS from falling back to the friend-add path).
function rpcError(err: unknown, fallback = 'database error') {
  let msg = fallback;
  if (typeof err === 'string') msg = err;
  else if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    msg = (err as { message: string }).message;
  } else if (err != null) {
    msg = String(err);
  }
  // Heuristic: a few well-known RPC exceptions map to non-500 codes.
  if (/auth required/i.test(msg)) return { status: 401 as const, body: { error: msg } };
  if (/forbidden|cannot remove|cannot leave/i.test(msg)) return { status: 403 as const, body: { error: msg } };
  if (/not found/i.test(msg)) return { status: 404 as const, body: { error: msg } };
  if (/already decided|full|invalid|too long|must|requires|empty|closed to new/i.test(msg)) {
    return { status: 400 as const, body: { error: msg } };
  }
  return { status: 500 as const, body: { error: 'database', detail: msg } };
}

// 群邀请卡片的"计费提示"文案。
//
// 旧 per-conversation 分摊模型已退役(表/列已物理 drop,迁移
// 20260611013529)—— 群消费改由责任 subject 的实缴池+认缴结算
// (billing/group-wallet.ts)。提示是常量,不再落库,GET /invitations
// 在响应里合成 billing_snapshot(iOS 解码 .text 的形状不变)。
function groupInviteBillingHint() {
  return {
    invitee_participates: true,
    text: '加入后，机器人 Token 由群钱包统一结算。',
  };
}

// ─────────────────────────────────────────────────────────────────────
// Create
// ─────────────────────────────────────────────────────────────────────

const CreateBody = z.object({
  title: z.string().max(80).optional(),
  memberUserIds: z.array(z.string().uuid()).max(29).default([]),
  memberBotIds: z.array(z.string().uuid()).max(29).default([]),
});

groupRoutes.post('/', async (c) => {
  const userJwt = c.var.userJwt!;
  let parsed: z.infer<typeof CreateBody>;
  try {
    parsed = CreateBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('open_group_conv', {
    p_title: parsed.title ?? '',
    p_initial_user_ids: [],
    p_initial_bot_ids: parsed.memberBotIds,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  if (data) {
    const supaSvc = serviceClient(c.env);
    await supaSvc
      .from('messages')
      .insert({
        client_message_id: crypto.randomUUID(),
        conversation_id: data,
        user_id: c.var.userId!,
        role: 'user',
        content: '群聊已创建',
        status: 'done',
        metadata: { source: 'group_system', event: 'created' },
      });
  }
  const invitationIds: string[] = [];
  if (data && parsed.memberUserIds.length > 0) {
    const supaSvc = serviceClient(c.env);
    for (const inviteeId of parsed.memberUserIds) {
      if (inviteeId === c.var.userId!) continue;
      const { data: invite, error: inviteErr } = await supaSvc
        .from('group_member_invitations')
        .insert({
          conversation_id: data as string,
          inviter_id: c.var.userId!,
          invitee_id: inviteeId,
          status: 'pending',
        })
        .select('id')
        .single();
      if (inviteErr) {
        return jsonError(c, 500, 'database_error', { detail: inviteErr.message });
      }
      if (invite?.id) invitationIds.push(invite.id as string);
    }
  }
  if (data) {
    trackEvent(c, AnalyticsEvent.GroupCreated, {
      group_id: data,
      bot_count: parsed.memberBotIds.length,
      invited_count: invitationIds.length,
    });
  }
  return c.json({ conversationId: data, invitationIds });
});

const TitleBody = z.object({
  title: z.string().trim().min(1).max(80),
});
groupRoutes.post('/:id/title', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof TitleBody>;
  try {
    parsed = TitleBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const userId = c.var.userId!;
  const role = await requireGroupRole(c.env, convId, userId, ['owner', 'admin']);
  if (!role.ok && role.code === 'database_error') {
    return jsonError(c, 500, 'database_error', { detail: role.detail });
  }
  if (!role.ok && role.code === 'forbidden' && role.role == null) {
    return jsonError(c, 403, 'not_a_participant');
  }
  if (!role.ok) {
    return jsonError(c, 403, 'forbidden', { message: '只有群主或管理员可以修改群名' });
  }

  const supa = serviceClient(c.env);
  const title = parsed.title;
  const now = new Date().toISOString();
  const [{ error: metaErr }, { error: convErr }] = await Promise.all([
    supa
      .from('conversation_group_meta')
      .update({ title, updated_at: now })
      .eq('conversation_id', convId),
    supa
      .from('conversations')
      .update({ title, updated_at: now })
      .eq('id', convId),
  ]);
  if (metaErr || convErr) {
    return jsonError(c, 500, 'database_error', { detail: metaErr?.message ?? convErr?.message });
  }
  return c.json({ ok: true, title });
});

// GET /v1/groups/random-name — returns a random place-name suggestion so
// the iOS create-group page can prefill a title (same logic as the
// auto-title fallback baked into start_user_bot_turn / open_user_bot_conv:
// pendingbot.random_place_name() draws from the seeded place_names table).
// Auth-gated via the groupRoutes middleware; cheap single-row read.
groupRoutes.get('/random-name', async (c) => {
  const supa = serviceClient(c.env);
  const { data, error } = await supa.rpc('random_place_name');
  if (error) {
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ name: (data as string | null) ?? '新群聊' });
});

// ─────────────────────────────────────────────────────────────────────
// Invite / remove
// ─────────────────────────────────────────────────────────────────────

const InviteUserBody = z.object({ userId: z.string().uuid() });
groupRoutes.post('/:id/invite-user', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof InviteUserBody>;
  try {
    parsed = InviteUserBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const inviterId = c.var.userId!;
  const roleCheck = await requireGroupRole(c.env, convId, inviterId, ['owner', 'admin']);
  if (!roleCheck.ok && roleCheck.code === 'database_error') {
    return jsonError(c, 500, 'database_error', { detail: roleCheck.detail });
  }
  if (!roleCheck.ok && roleCheck.code === 'forbidden' && roleCheck.role == null) {
    return jsonError(c, 403, 'not_a_participant');
  }
  if (!roleCheck.ok) {
    return jsonError(c, 403, 'forbidden', { message: '只有群主或管理员可以邀请成员' });
  }

  const supa = serviceClient(c.env);
  const [{ data: target }, { data: existing }] = await Promise.all([
    supa.from('users').select('id').eq('id', parsed.userId).maybeSingle(),
    supa
      .from('conversation_participants')
      .select('participant_id')
      .eq('conversation_id', convId)
      .eq('participant_type', 'user')
      .eq('participant_id', parsed.userId)
      .maybeSingle(),
  ]);
  if (!target) return jsonError(c, 404, 'peer_not_found', { message: '用户不存在' });
  if (existing) return jsonError(c, 409, 'conflict', { message: '对方已经在群里' });

  const hint = groupInviteBillingHint();

  const { data: pendingExisting, error: pendingErr } = await supa
    .from('group_member_invitations')
    .select('id')
    .eq('conversation_id', convId)
    .eq('invitee_id', parsed.userId)
    .eq('status', 'pending')
    .maybeSingle();
  if (pendingErr) return jsonError(c, 500, 'database_error', { detail: pendingErr.message });

  const { data, error } = pendingExisting
    ? { data: pendingExisting, error: null }
    : await supa
      .from('group_member_invitations')
      .insert({
        conversation_id: convId,
        inviter_id: inviterId,
        invitee_id: parsed.userId,
        status: 'pending',
        decided_at: null,
      })
      .select('id')
      .single();
  if (error || !data) return jsonError(c, 500, 'database_error', { detail: error?.message });

  return c.json({
    ok: true,
    pending: true,
    invitationId: data.id,
    billing: hint,
  });
});

groupRoutes.get('/invitations', async (c) => {
  const userId = c.var.userId!;
  const supa = serviceClient(c.env);
  const { data, error } = await supa
    .from('group_member_invitations')
    .select('id, conversation_id, inviter_id, invitee_id, status, created_at, decided_at')
    .eq('invitee_id', userId)
    .order('created_at', { ascending: false });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });

  const convIds = Array.from(new Set((data ?? []).map((r) => r.conversation_id as string)));
  const inviterIds = Array.from(new Set((data ?? []).map((r) => r.inviter_id as string)));
  const [{ data: metas, error: metaErr }, { data: inviters, error: inviterErr }] = await Promise.all([
    convIds.length
      ? supa.from('conversation_group_meta').select('conversation_id, title').in('conversation_id', convIds)
      : Promise.resolve({ data: [], error: null }),
    inviterIds.length
      ? supa.from('users').select('id, display_name, avatar_path, custom_fields').in('id', inviterIds)
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (metaErr || inviterErr) {
    return jsonError(c, 500, 'database_error', { detail: metaErr?.message ?? inviterErr?.message });
  }
  const titleByConv = new Map((metas ?? []).map((m) => [m.conversation_id as string, (m.title as string | null) ?? '群聊']));
  const inviterById = new Map((inviters ?? []).map((u) => {
    const cf = u.custom_fields as Record<string, unknown> | null;
    return [u.id as string, {
      display_name: (u.display_name as string | null) ?? '',
      avatar_path: (u.avatar_path as string | null) ?? null,
      avatar_seed: typeof cf?.avatar_seed === 'string' ? cf.avatar_seed : (u.id as string),
    }];
  }));

  // billing_snapshot 不再落库(死分摊模型的快照列已 drop),响应里合成常量
  // 提示,保持 iOS 解码形状(row.billing_snapshot?.text)不变。
  const hint = groupInviteBillingHint();
  return c.json({
    invitations: (data ?? []).map((r) => ({
      ...r,
      billing_snapshot: hint,
      invitee_participates: hint.invitee_participates,
      group_title: titleByConv.get(r.conversation_id as string) ?? '群聊',
      inviter: inviterById.get(r.inviter_id as string) ?? {
        display_name: '',
        avatar_path: null,
        avatar_seed: r.inviter_id,
      },
    })),
  });
});

const InvitationDecisionBody = z.object({ approve: z.boolean() });
groupRoutes.post('/invitations/:inviteId/decide', async (c) => {
  const inviteId = c.req.param('inviteId');
  let parsed: z.infer<typeof InvitationDecisionBody>;
  try {
    parsed = InvitationDecisionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const userId = c.var.userId!;
  const supa = serviceClient(c.env);
  const { data: invite, error: inviteErr } = await supa
    .from('group_member_invitations')
    .select('id, conversation_id, invitee_id, status')
    .eq('id', inviteId)
    .maybeSingle();
  if (inviteErr) return jsonError(c, 500, 'database_error', { detail: inviteErr.message });
  if (!invite) return jsonError(c, 404, 'request_not_found');
  if (invite.invitee_id !== userId) return jsonError(c, 403, 'request_not_yours');
  if (invite.status !== 'pending') return jsonError(c, 409, 'conflict', { message: '邀请已处理' });

  const decidedStatus = parsed.approve ? 'approved' : 'rejected';
  const now = new Date().toISOString();
  if (parsed.approve) {
    const { data: meta, error: metaErr } = await supa
      .from('conversation_group_meta')
      .select('max_members')
      .eq('conversation_id', invite.conversation_id)
      .maybeSingle();
    if (metaErr) return jsonError(c, 500, 'database_error', { detail: metaErr.message });
    const { count, error: countErr } = await supa
      .from('conversation_participants')
      .select('participant_id', { count: 'exact', head: true })
      .eq('conversation_id', invite.conversation_id);
    if (countErr) return jsonError(c, 500, 'database_error', { detail: countErr.message });
    if ((count ?? 0) >= (meta?.max_members ?? 100)) {
      return jsonError(c, 400, 'conflict', { message: '群成员已满' });
    }
    const { error: partErr } = await supa.from('conversation_participants').insert({
      conversation_id: invite.conversation_id,
      participant_type: 'user',
      participant_id: userId,
      role: 'member',
    });
    if (partErr) {
      return jsonError(c, 500, 'database_error', { detail: partErr.message });
    }
  }

  const { error: updateErr } = await supa
    .from('group_member_invitations')
    .update({ status: decidedStatus, decided_at: now })
    .eq('id', inviteId);
  if (updateErr) return jsonError(c, 500, 'database_error', { detail: updateErr.message });

  if (parsed.approve) {
    trackEvent(c, AnalyticsEvent.GroupJoined, {
      group_id: invite.conversation_id,
      via: 'invitation',
    });
  }

  return c.json({ ok: true, status: decidedStatus, conversationId: invite.conversation_id });
});

const InviteBotBody = z.object({ botId: z.string().uuid() });
groupRoutes.post('/:id/invite-bot', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof InviteBotBody>;
  try {
    parsed = InviteBotBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_invite_bot', {
    p_conv_id: convId,
    p_bot_id: parsed.botId,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  // Kick off the first-description LLM call in the background. The
  // RPC has already added the bot to the group; the description is
  // an enhancement for the router and shouldn't block the invite UI.
  // Audit billing resolves the group split from conversationId.
  c.executionCtx.waitUntil(
    generateInitialBotDescription({
      env: c.env,
      conversationId: convId,
      botId: parsed.botId,
    })
      .then((res) => {
        console.log('[invite-bot] description generated',
          { convId, botId: parsed.botId, len: res.description.length });
      })
      .catch((err) => console.error('[invite-bot] description gen failed', err)),
  );
  return c.json({ ok: true, descriptionPending: true });
});

const RemoveMemberBody = z.object({ userId: z.string().uuid() });
groupRoutes.post('/:id/remove-user', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof RemoveMemberBody>;
  try {
    parsed = RemoveMemberBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_remove_member', {
    p_conv_id: convId,
    p_target_user_id: parsed.userId,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

// Convenience self-leave — same RPC, target = caller.
groupRoutes.post('/:id/leave', async (c) => {
  const convId = c.req.param('id');
  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_remove_member', {
    p_conv_id: convId,
    p_target_user_id: c.var.userId!,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const RemoveBotBody = z.object({ botId: z.string().uuid() });
groupRoutes.post('/:id/remove-bot', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof RemoveBotBody>;
  try {
    parsed = RemoveBotBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_remove_bot', {
    p_conv_id: convId,
    p_bot_id: parsed.botId,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const SetRoleBody = z.object({
  userId: z.string().uuid(),
  role: z.enum(['admin', 'member']),
});
groupRoutes.post('/:id/role', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof SetRoleBody>;
  try {
    parsed = SetRoleBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_member_role', {
    p_conv_id: convId,
    p_target_user_id: parsed.userId,
    p_role: parsed.role,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────
// Nicknames
// ─────────────────────────────────────────────────────────────────────

const NicknameBody = z.object({ nickname: z.string().max(32).nullable() });
groupRoutes.post('/:id/nickname', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof NicknameBody>;
  try {
    parsed = NicknameBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_member_nickname', {
    p_conv_id: convId,
    p_nickname: parsed.nickname ?? '',
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const BotNicknameBody = z.object({
  botId: z.string().uuid(),
  nickname: z.string().max(32).nullable(),
});
groupRoutes.post('/:id/bot-nickname', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof BotNicknameBody>;
  try {
    parsed = BotNicknameBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_bot_nickname', {
    p_conv_id: convId,
    p_bot_id: parsed.botId,
    p_nickname: parsed.nickname ?? '',
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

// Owner/admin-only manual edit of a bot's per-group description. The
// bot's own self-rewrite goes through the tool path, not this route.
const BotDescriptionBody = z.object({
  botId: z.string().uuid(),
  description: z.string().min(1).max(4000),
});
groupRoutes.post('/:id/bot-description', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof BotDescriptionBody>;
  try {
    parsed = BotDescriptionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_bot_description', {
    p_conv_id: convId,
    p_bot_id: parsed.botId,
    p_description: parsed.description,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────
// Mute
// ─────────────────────────────────────────────────────────────────────
//
// 旧的 per-conversation 分摊配置(/billing、/cap、/participates)已退役 ——
// 群消费改由责任 subject 的实缴池+认缴模型结算(billing/group-wallet.ts
// settleGroupSpend),配置入口移到群钱包页(/v1/group-subjects/:id/*)。
// group_member_billing 表已物理 drop(迁移 20260611013529);mute 状态只存
// conversation_participants.muted,group_set_member_mute RPC 只写那一处。

const MuteBody = z.object({ muted: z.boolean() });
groupRoutes.post('/:id/mute', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof MuteBody>;
  try {
    parsed = MuteBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_member_mute', {
    p_conv_id: convId,
    p_muted: parsed.muted,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────
// Handles + join policy + join requests
// ─────────────────────────────────────────────────────────────────────

const HandleBody = z.object({
  handleType: z.enum(['number', 'qr']),
  // Empty string = clear / disable.
  value: z.string().max(20),
});
groupRoutes.post('/:id/handle', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof HandleBody>;
  try {
    parsed = HandleBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_handle', {
    p_conv_id: convId,
    p_handle_type: parsed.handleType,
    p_value: parsed.value,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const PolicyBody = z.object({ policy: z.enum(['scan_open', 'approval', 'closed']) });
groupRoutes.post('/:id/policy', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof PolicyBody>;
  try {
    parsed = PolicyBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_join_policy', {
    p_conv_id: convId,
    p_policy: parsed.policy,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const JoinRequestBody = z.object({
  handleValue: z.string().min(4).max(20),
  message: z.string().max(200).optional(),
});
// POST /v1/groups/join — caller doesn't know the conversation_id yet,
// they only have a scanned/typed handle. RPC resolves it.
groupRoutes.post('/join', async (c) => {
  // Same rate-limit family as friend-request /lookup — handle values
  // are the enumerable resource here too.
  const blocked = await rateLimitOrBlock(c, c.env.HANDLE_LOOKUP_RL);
  if (blocked) return blocked;

  let parsed: z.infer<typeof JoinRequestBody>;
  try {
    parsed = JoinRequestBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('group_join_request_create', {
    p_handle_value: parsed.handleValue,
    p_message: parsed.message ?? '',
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  // RPC returns a setof-row; supabase-js gives an array.
  const row = Array.isArray(data) ? data[0] : data;
  return c.json({
    conversationId: row?.conversation_id ?? null,
    requestId: row?.request_id ?? null,
    joined: row?.joined ?? false,
  });
});

const DecideBody = z.object({
  requestId: z.string().uuid(),
  approve: z.boolean(),
});
groupRoutes.post('/:id/join-decide', async (c) => {
  let parsed: z.infer<typeof DecideBody>;
  try {
    parsed = DecideBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_join_request_decide', {
    p_request_id: parsed.requestId,
    p_approve: parsed.approve,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

// GET /v1/groups/:id/join-requests — owner/admin sees all; member sees
// own. RLS handles the gate (two policies on the table).
groupRoutes.get('/:id/join-requests', async (c) => {
  const convId = c.req.param('id');
  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa
    .from('group_join_requests')
    .select('id, conversation_id, requester_id, via_handle_id, status, message, decided_by, decided_at, created_at')
    .eq('conversation_id', convId)
    .order('created_at', { ascending: false });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  const requesterIds = Array.from(new Set((data ?? []).map((r) => r.requester_id as string)));
  let profilesById = new Map<string, {
    display_name: string | null;
    avatar_path: string | null;
    avatar_seed: string;
  }>();
  if (requesterIds.length > 0) {
    const supaSvc = serviceClient(c.env);
    const { data: profiles, error: profileErr } = await supaSvc
      .from('users')
      .select('id, display_name, avatar_path, custom_fields')
      .in('id', requesterIds);
    if (profileErr) return jsonError(c, 500, 'database_error', { detail: profileErr.message });
    profilesById = new Map((profiles ?? []).map((p) => {
      const cf = p.custom_fields as Record<string, unknown> | null;
      const seed = typeof cf?.avatar_seed === 'string' && cf.avatar_seed.length > 0
        ? cf.avatar_seed
        : (p.id as string);
      return [p.id as string, {
        display_name: (p.display_name as string | null) ?? null,
        avatar_path: (p.avatar_path as string | null) ?? null,
        avatar_seed: seed,
      }];
    }));
  }
  return c.json({
    requests: (data ?? []).map((r) => {
      const profile = profilesById.get(r.requester_id as string);
      return {
        ...r,
        requester_display_name: profile?.display_name ?? '',
        requester_avatar_path: profile?.avatar_path ?? null,
        requester_avatar_seed: profile?.avatar_seed ?? (r.requester_id as string),
      };
    }),
  });
});

// ─────────────────────────────────────────────────────────────────────
// Continue-vote decision (anti-loop). M3+ wires the actual prompt
// insertion; this endpoint exists now so iOS can already render the
// allow/deny buttons against the real backend.
// ─────────────────────────────────────────────────────────────────────

const ContinueDecisionBody = z.object({
  requestId: z.string().uuid(),
  decision: z.enum(['allowed', 'denied']),
});
groupRoutes.post('/:id/continue-decision', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof ContinueDecisionBody>;
  try {
    parsed = ContinueDecisionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Cross-check that the requestId actually belongs to this conv. The
  // message insert below uses service-role (bypasses RLS); without this
  // guard a caller could pass `:id` for any group and a `requestId` from
  // a group they actually belong to — injecting a 「✅ 让机器人继续」
  // message into a third-party group.
  const userId = c.var.userId!;
  const supaSvc = serviceClient(c.env);
  const { data: req, error: reqErr } = await supaSvc
    .from('group_continue_requests')
    .select('conversation_id')
    .eq('id', parsed.requestId)
    .maybeSingle();
  if (reqErr) return jsonError(c, 500, 'database_error', { detail: reqErr.message });
  if (!req) return jsonError(c, 404, 'request_not_found');
  if (req.conversation_id !== convId) {
    return jsonError(c, 400, 'request_not_found', { message: 'request does not belong to this conversation' });
  }

  // Explicit membership check: the caller must be a participant of the
  // conversation. RLS on group_continue_requests would normally hide
  // requests outside the user's groups, but the lookup above uses
  // service-role for a consistent 404 vs 403 surface, so we re-prove
  // membership here before writing a message attributed to the user.
  const membership = await isGroupHumanParticipant(c.env, convId, userId);
  if (!membership.ok && membership.code === 'database_error') {
    return jsonError(c, 500, 'database_error', { detail: membership.detail });
  }
  if (!membership.ok) return jsonError(c, 403, 'not_a_participant');

  const decisionText = parsed.decision === 'allowed' ? '✅ 让机器人继续' : '❌ 让机器人闭嘴';

  const { data: msg, error: msgErr } = await supaSvc
    .from('messages')
    .insert({
      client_message_id: crypto.randomUUID(),
      conversation_id: convId,
      user_id: userId,
      role: 'user',
      content: decisionText,
      status: 'done',
    })
    .select('id')
    .single();
  if (msgErr || !msg) return jsonError(c, 500, 'database_error', { detail: msgErr?.message });

  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('group_continue_decide', {
    p_request_id: parsed.requestId,
    p_decision_message_id: msg.id,
    p_decision: parsed.decision,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }

  // On 'allowed', kick the DO's /resume path so the previously-pending
  // bots actually speak. The 30s anti-loop window is implicitly reset
  // because we just inserted the human's decision message.
  // The decided row carries pending_bot_ids.
  if (parsed.decision === 'allowed') {
    const decided = (Array.isArray(data) ? data[0] : data) as
      | { pending_bot_ids?: string[]; conversation_id?: string }
      | null;
    const wakeBotIds = decided?.pending_bot_ids ?? [];
    if (wakeBotIds.length > 0) {
      const doId = c.env.GROUP_ROUTER.idFromName(convId);
      const stub = c.env.GROUP_ROUTER.get(doId);
      c.executionCtx.waitUntil(
        stub
          .fetch('https://group-router.internal/resume', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ conversationId: convId, wakeBotIds }),
          })
          .catch((err) => console.error('[continue-decision] DO resume failed', err)),
      );
    }
  }

  return c.json({ ok: true, decisionMessageId: msg.id, request: data });
});
