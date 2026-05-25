import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import { rateLimitOrBlock } from '../lib/rate-limit';
import { jsonError } from '../lib/http-error';
import { isGroupHumanParticipant, loadGroupConversationForUser } from '../lib/route-authz';
import type { AppBindings } from '../types';

// /v1/friend-requests — request/accept gate for human-to-human chat.
//
// Flow:
//   GET  /lookup?handleValue=…  — preview a user (avatar + nickname) before
//                                  the sender commits to a request. Returns
//                                  only the two display fields by design —
//                                  no email, no created_at, no other PII.
//   POST /                — A creates a pending request to B by handle.
//                           Optional `message` is the verification text B
//                           sees alongside the request (WeChat-style). The
//                           legacy `remark` body field is still accepted as
//                           a fallback alias-on-accept path but is no longer
//                           how iOS surfaces the entry.
//   GET  /                — list my incoming + outgoing
//   POST /:id/accept      — B accepts; RPC writes user_contacts both ways
//   POST /:id/decline     — B declines; row stays for audit
//   POST /:id/cancel      — A cancels their own pending request
//
// Writes go through service-role; the RLS on friend_requests only exposes
// SELECT to either party. The accept side-effect (symmetric user_contacts
// rows) lives in pendingbot.accept_friend_request — see migrations
// 0046 / 0049 / 0061. Aliases for an existing contact are set separately
// via PATCH /v1/contacts/:contactUserId.

export const friendRequestRoutes = new Hono<AppBindings>();
friendRequestRoutes.use('*', requireSession());

// Either path: classic handle-based add (`handleValue`) for QR / number
// scans, or peer-id-based add (`peerUserId`) for the in-group "加他好友"
// flow where iOS already knows the user_id from the participants list.
// Exactly one must be provided. The peer-id path must also carry the source
// group conversation so the server can prove both users are in that group;
// otherwise a guessed UUID would be enough to send unsolicited requests.
//
// `message` is the verification text the recipient sees before accepting
// (WeChat-style). `remark` is the legacy field that became the sender's
// alias-on-accept; kept for backward compat but iOS no longer surfaces it
// from the add-friend sheet — aliases are set later via PATCH /contacts/:id.
const CreateBody = z
  .object({
    handleValue: z.string().min(4).max(64).optional(),
    peerUserId: z.string().uuid().optional(),
    sourceConversationId: z.string().uuid().optional(),
    message: z.string().max(200).optional(),
    remark: z.string().max(64).optional(),
  })
  .refine(
    (v) => (v.handleValue ? 1 : 0) + (v.peerUserId ? 1 : 0) === 1,
    { message: 'must specify exactly one of handleValue or peerUserId' },
  )
  .refine(
    (v) => (v.peerUserId ? !!v.sourceConversationId : !v.sourceConversationId),
    { message: 'sourceConversationId is required only for peerUserId requests' },
  );

// Preview a user by handle. Used by the iOS 加好友 page after the user
// finishes typing the number, so they can confirm "this is the person I
// meant" before sending the request. Intentionally returns only the
// display fields — exposing email or created_at here would leak data
// beyond what the recipient consented to via their handle.
friendRequestRoutes.get('/lookup', async (c) => {
  const blocked = await rateLimitOrBlock(c, c.env.HANDLE_LOOKUP_RL);
  if (blocked) return blocked;

  const handleValue = c.req.query('handleValue')?.trim();
  if (!handleValue || handleValue.length < 4 || handleValue.length > 64) {
    return jsonError(c, 400, 'handle_required');
  }
  const supa = serviceClient(c.env);
  const { data: handle, error } = await supa
    .from('user_handles')
    .select('user_id, is_active')
    .eq('value', handleValue)
    .maybeSingle();
  if (error) return jsonError(c, 500, 'database_error', { message: '号码查询失败,请稍后重试', detail: error.message });
  if (!handle || !handle.is_active) return jsonError(c, 404, 'handle_not_found', { message: '号码无效或已撤销' });

  const { data: profile, error: profErr } = await supa
    .from('users')
    .select('id, display_name, avatar_path, custom_fields')
    .eq('id', handle.user_id as string)
    .maybeSingle();
  if (profErr) return jsonError(c, 500, 'database_error', { detail: profErr.message });
  if (!profile) return jsonError(c, 404, 'handle_not_found', { message: '号码无效或已撤销' });

  const cf = profile.custom_fields as Record<string, unknown> | null;
  const seed = (typeof cf?.avatar_seed === 'string' && cf.avatar_seed.length > 0)
    ? cf.avatar_seed
    : (profile.id as string);

  return c.json({
    userId: profile.id as string,
    displayName: (profile.display_name as string | null) ?? '',
    avatarPath: (profile.avatar_path as string | null) ?? null,
    avatarSeed: seed,
  });
});

friendRequestRoutes.post('/', async (c) => {
  // Share the same enumeration limiter as /lookup — POST / can be used
  // for blind brute-force the same way (each rejection 404 still
  // confirms whether the handle is registered).
  const blocked = await rateLimitOrBlock(c, c.env.HANDLE_LOOKUP_RL);
  if (blocked) return blocked;

  const userId = c.var.userId!;
  let parsed: z.infer<typeof CreateBody>;
  try {
    parsed = CreateBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = serviceClient(c.env);

  // Resolve target user. Handle path looks the value up in user_handles
  // and pins the resulting friend row to that handle (so the recipient
  // can see "joined via blog"). Peer-id path skips the handle lookup
  // entirely — used by the in-group "加他好友" prompt where the caller
  // already has the participant's user_id.
  let targetUserId: string;
  let viaHandleId: string | null = null;
  if (parsed.handleValue) {
    const { data: handle, error: handleErr } = await supa
      .from('user_handles')
      .select('id, user_id, is_active')
      .eq('value', parsed.handleValue)
      .maybeSingle();
    if (handleErr) return jsonError(c, 500, 'database_error', { message: '号码查询失败,请稍后重试', detail: handleErr.message });
    if (!handle || !handle.is_active) return jsonError(c, 404, 'handle_not_found', { message: '号码无效或已撤销' });
    targetUserId = handle.user_id as string;
    viaHandleId = handle.id as string;
  } else {
    targetUserId = parsed.peerUserId!;
    const source = await loadGroupConversationForUser(
      c.env,
      c.var.userJwt!,
      userId,
      parsed.sourceConversationId!,
    );
    if (!source.ok) {
      if (source.code === 'database_error') {
        return jsonError(c, 500, 'database_error', { detail: source.detail });
      }
      return jsonError(c, 403, 'source_group_forbidden', { message: '只能从共同群聊里加好友' });
    }
    const targetInGroup = await isGroupHumanParticipant(c.env, parsed.sourceConversationId!, targetUserId);
    if (!targetInGroup.ok) {
      if (targetInGroup.code === 'database_error') {
        return jsonError(c, 500, 'database_error', { detail: targetInGroup.detail });
      }
      return jsonError(c, 403, 'peer_not_in_source_group', { message: '只能添加同群成员' });
    }
    const { data: peer, error: peerErr } = await supa
      .from('users')
      .select('id')
      .eq('id', targetUserId)
      .maybeSingle();
    if (peerErr) return jsonError(c, 500, 'database_error', { detail: peerErr.message });
    if (!peer) return jsonError(c, 404, 'peer_not_found', { message: '用户不存在' });
  }

  if (targetUserId === userId) return jsonError(c, 400, 'cannot_add_self', { message: '不能加自己' });

  const remark = parsed.remark?.trim() || null;
  const message = parsed.message?.trim() || null;

  // Already contacts → 200 with `alreadyContacts: true`. iOS surfaces this as
  // "你们已经是好友" and routes to the existing chat instead of asking again.
  const { data: existingContact } = await supa
    .from('user_contacts')
    .select('contact_user_id')
    .eq('user_id', userId)
    .eq('contact_user_id', targetUserId)
    .maybeSingle();
  if (existingContact) {
    return c.json({ alreadyContacts: true });
  }

  // Mutual-pending shortcut: if the recipient has already sent ME a
  // pending request, auto-accept theirs instead of stacking a second
  // request in the opposite direction. This matches the natural mental
  // model where two people simultaneously try to add each other.
  const { data: theirPending } = await supa
    .from('friend_requests')
    .select('id')
    .eq('from_user_id', targetUserId)
    .eq('to_user_id', userId)
    .eq('status', 'pending')
    .maybeSingle();
  if (theirPending?.id) {
    const { error: rpcErr } = await supa.rpc('accept_friend_request', {
      p_request_id: theirPending.id,
      p_user_id: userId,
    });
    if (rpcErr) return jsonError(c, 500, 'database_error', { message: '处理对方申请失败,请稍后重试', detail: rpcErr.message });
    // accept_friend_request only carries an alias from the *other* side's
    // remark_for_contact. Our own remark would be dropped here, so write
    // it explicitly into our user_contacts row for the new friend.
    if (remark) {
      await supa
        .from('user_contacts')
        .update({ alias: remark })
        .eq('user_id', userId)
        .eq('contact_user_id', targetUserId);
    }
    return c.json({ autoAccepted: true, requestId: theirPending.id });
  }

  // Otherwise create our own pending request. The unique partial index
  // friend_requests_one_pending_per_pair stops duplicates on the same
  // direction; surface that as a 409 so iOS can show "已发送过申请".
  const { data: created, error: insertErr } = await supa
    .from('friend_requests')
    .insert({
      from_user_id: userId,
      to_user_id: targetUserId,
      status: 'pending',
      message,
      remark_for_contact: remark,
      via_handle_id: viaHandleId,
    })
    .select('id')
    .single();
  if (insertErr) {
    if ((insertErr as { code?: string }).code === '23505') {
      return jsonError(c, 409, 'conflict', { message: '已发送过申请,等对方回复' });
    }
    return jsonError(c, 500, 'database_error', { message: '发送申请失败,请稍后重试', detail: insertErr.message });
  }
  return c.json({ requestId: created!.id, status: 'pending' });
});

friendRequestRoutes.get('/', async (c) => {
  const userId = c.var.userId!;
  const direction = c.req.query('direction'); // 'incoming' | 'outgoing' | undefined
  const supa = serviceClient(c.env);

  // Service-role read so we can attach the peer's display_name in one
  // query rather than forcing the client to chase per-row profile lookups.
  // The `or` filter mirrors what RLS would have allowed if we read as the
  // user.
  let query = supa
    .from('friend_requests')
    .select(
      'id, from_user_id, to_user_id, status, message, via_email, created_at, responded_at',
    )
    .order('created_at', { ascending: false });

  if (direction === 'incoming') {
    query = query.eq('to_user_id', userId);
  } else if (direction === 'outgoing') {
    query = query.eq('from_user_id', userId);
  } else {
    query = query.or(`from_user_id.eq.${userId},to_user_id.eq.${userId}`);
  }

  const { data: rows, error } = await query;
  if (error) return jsonError(c, 500, 'database_error', { message: '加载申请列表失败,请稍后重试', detail: error.message });

  // Attach peer profile (the other side relative to the caller) so iOS
  // can render a name without a follow-up trip per row. Single batched
  // lookup against pendingbot.users.
  const peerIds = Array.from(
    new Set((rows ?? []).map((r) => (r.from_user_id === userId ? r.to_user_id : r.from_user_id))),
  );
  let profilesById: Record<string, {
    display_name: string;
    avatar_path: string | null;
    avatar_seed: string;
  }> = {};
  if (peerIds.length > 0) {
    const { data: profiles } = await supa
      .from('users')
      .select('id, display_name, avatar_path, custom_fields')
      .in('id', peerIds);
    for (const p of profiles ?? []) {
      const cf = p.custom_fields as Record<string, unknown> | null;
      const seed = (typeof cf?.avatar_seed === 'string' && cf.avatar_seed.length > 0)
        ? cf.avatar_seed
        : (p.id as string);
      profilesById[p.id as string] = {
        display_name: (p.display_name as string) ?? '',
        avatar_path: (p.avatar_path as string | null) ?? null,
        avatar_seed: seed,
      };
    }
  }

  const enriched = (rows ?? []).map((r) => {
    const incoming = r.to_user_id === userId;
    const peerId = incoming ? r.from_user_id : r.to_user_id;
    const profile = profilesById[peerId as string];
    return {
      id: r.id,
      direction: incoming ? 'incoming' : 'outgoing',
      status: r.status,
      message: r.message,
      viaEmail: r.via_email,
      createdAt: r.created_at,
      respondedAt: r.responded_at,
      peerUserId: peerId,
      peerDisplayName: profile?.display_name ?? '',
      peerAvatarPath: profile?.avatar_path ?? null,
      peerAvatarSeed: profile?.avatar_seed ?? (peerId as string),
    };
  });

  return c.json({ requests: enriched });
});

friendRequestRoutes.post('/:id/accept', async (c) => {
  const userId = c.var.userId!;
  const requestId = c.req.param('id');
  const supa = serviceClient(c.env);

  // Verify recipient + pending. The RPC re-checks under FOR UPDATE, but we
  // pre-flight here so the error surface for "wrong user" is a clean 403
  // rather than the RPC's generic exception. Worth one extra read.
  const { data: rq, error: readErr } = await supa
    .from('friend_requests')
    .select('id, to_user_id, status')
    .eq('id', requestId)
    .maybeSingle();
  if (readErr) return jsonError(c, 500, 'database_error', { message: '读取申请失败,请稍后重试', detail: readErr.message });
  if (!rq) return jsonError(c, 404, 'request_not_found', { message: '该申请不存在' });
  if (rq.to_user_id !== userId) return jsonError(c, 403, 'request_not_yours', { message: '不是你的申请' });
  if (rq.status !== 'pending') return jsonError(c, 409, 'conflict', { message: '该申请已处理' });

  const { error: rpcErr } = await supa.rpc('accept_friend_request', {
    p_request_id: requestId,
    p_user_id: userId,
  });
  if (rpcErr) return jsonError(c, 500, 'database_error', { message: '接受申请失败,请稍后重试', detail: rpcErr.message });

  // iOS uses peerUserId to navigate straight into the chat once accepted,
  // so the user doesn't have to scroll to find the new friend's row.
  const { data: full } = await supa
    .from('friend_requests')
    .select('from_user_id')
    .eq('id', requestId)
    .maybeSingle();
  return c.json({ ok: true, peerUserId: full?.from_user_id ?? null });
});

friendRequestRoutes.post('/:id/decline', async (c) => {
  const userId = c.var.userId!;
  const requestId = c.req.param('id');
  const supa = serviceClient(c.env);

  // Two-condition update so concurrent calls or already-handled rows
  // can't be re-declined silently. We surface 0-row updates as 409.
  const { data: updated, error } = await supa
    .from('friend_requests')
    .update({ status: 'declined', responded_at: new Date().toISOString() })
    .eq('id', requestId)
    .eq('to_user_id', userId)
    .eq('status', 'pending')
    .select('id');
  if (error) return jsonError(c, 500, 'database_error', { message: '拒绝申请失败,请稍后重试', detail: error.message });
  if (!updated || updated.length === 0) {
    return jsonError(c, 409, 'conflict', { message: '申请不存在或已处理' });
  }
  return c.json({ ok: true });
});

friendRequestRoutes.post('/:id/cancel', async (c) => {
  const userId = c.var.userId!;
  const requestId = c.req.param('id');
  const supa = serviceClient(c.env);

  const { data: updated, error } = await supa
    .from('friend_requests')
    .update({ status: 'cancelled', responded_at: new Date().toISOString() })
    .eq('id', requestId)
    .eq('from_user_id', userId)
    .eq('status', 'pending')
    .select('id');
  if (error) return jsonError(c, 500, 'database_error', { message: '撤回申请失败,请稍后重试', detail: error.message });
  if (!updated || updated.length === 0) {
    return jsonError(c, 409, 'conflict', { message: '申请不存在或已处理' });
  }
  return c.json({ ok: true });
});
