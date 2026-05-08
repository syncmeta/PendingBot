import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { generateInitialBotDescription } from '../lib/group-bot-intro';
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
function rpcError(err: unknown, fallback = 'database error') {
  const msg = err instanceof Error ? err.message : String(err ?? fallback);
  // Heuristic: a few well-known RPC exceptions map to non-500 codes.
  if (/auth required/i.test(msg)) return { status: 401 as const, body: { error: msg } };
  if (/forbidden|cannot remove|cannot leave/i.test(msg)) return { status: 403 as const, body: { error: msg } };
  if (/not found/i.test(msg)) return { status: 404 as const, body: { error: msg } };
  if (/already decided|full|invalid|too long|must|requires|empty/i.test(msg)) {
    return { status: 400 as const, body: { error: msg } };
  }
  return { status: 500 as const, body: { error: 'database', detail: msg } };
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('open_group_conv', {
    p_title: parsed.title ?? '',
    p_initial_user_ids: parsed.memberUserIds,
    p_initial_bot_ids: parsed.memberBotIds,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ conversationId: data });
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_invite_user', {
    p_conv_id: convId,
    p_target_user_id: parsed.userId,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const InviteBotBody = z.object({ botId: z.string().uuid() });
groupRoutes.post('/:id/invite-bot', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof InviteBotBody>;
  try {
    parsed = InviteBotBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
  // The cost lands on the conv creator until M6 wires splitAndDebit.
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
// Billing config + caps + mute
// ─────────────────────────────────────────────────────────────────────

const BillingBody = z.object({
  mode: z.enum(['custom', 'per_head', 'per_message', 'per_token', 'hybrid']),
  windowSeconds: z.number().int().positive().max(30 * 86400),
  customShares: z
    .array(
      z.object({
        userId: z.string().uuid(),
        weightBps: z.number().int().min(0).max(10000),
      }),
    )
    .optional(),
});
groupRoutes.post('/:id/billing', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof BillingBody>;
  try {
    parsed = BillingBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_billing', {
    p_conv_id: convId,
    p_mode: parsed.mode,
    p_window_seconds: parsed.windowSeconds,
    p_custom_shares:
      parsed.mode === 'custom'
        ? (parsed.customShares ?? []).map((s) => ({
            user_id: s.userId,
            weight_bps: s.weightBps,
          }))
        : null,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const CapBody = z.object({ capCredits: z.number().int().nonnegative().nullable() });
groupRoutes.post('/:id/cap', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof CapBody>;
  try {
    parsed = CapBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supa = userClient(c.env, c.var.userJwt!);
  // supabase gen types emits `p_cap_credits: number` (non-null) because
  // the SQL bigint param has no DEFAULT — but passing null is the
  // documented "remove cap" path. JSON-null serializes correctly to
  // PostgREST; the cast is a type-only workaround.
  const { error } = await supa.rpc('group_set_member_cap', {
    p_conv_id: convId,
    p_cap_credits: parsed.capCredits as unknown as number,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const ParticipatesBody = z.object({
  userId: z.string().uuid(),
  participates: z.boolean(),
});
groupRoutes.post('/:id/participates', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof ParticipatesBody>;
  try {
    parsed = ParticipatesBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_set_member_participates', {
    p_conv_id: convId,
    p_target_user_id: parsed.userId,
    p_participates: parsed.participates,
  });
  if (error) {
    const e = rpcError(error);
    return c.json(e.body, e.status);
  }
  return c.json({ ok: true });
});

const MuteBody = z.object({ muted: z.boolean() });
groupRoutes.post('/:id/mute', async (c) => {
  const convId = c.req.param('id');
  let parsed: z.infer<typeof MuteBody>;
  try {
    parsed = MuteBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
  let parsed: z.infer<typeof JoinRequestBody>;
  try {
    parsed = JoinRequestBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
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
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ requests: data ?? [] });
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
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // Insert a normal user message expressing the decision so the whole
  // group can see who said yes/no. Service-role insert is fine: we trust
  // the caller's identity from requireSession() and the RPC verifies
  // group membership + status before linking.
  const userId = c.var.userId!;
  const supaSvc = serviceClient(c.env);
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
  if (msgErr || !msg) return c.json({ error: 'database', detail: msgErr?.message }, 500);

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
