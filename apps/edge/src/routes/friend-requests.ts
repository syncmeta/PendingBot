import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import type { AppBindings } from '../types';

// /v1/friend-requests — request/accept gate for human-to-human chat.
//
// Flow:
//   GET  /lookup?handleValue=…  — preview a user (avatar + nickname) before
//                                  the sender commits to a request. Returns
//                                  only the two display fields by design —
//                                  no email, no created_at, no other PII.
//   POST /                — A creates a pending request to B by handle.
//                           Optional `remark` becomes A's user_contacts.alias
//                           for B once B accepts.
//   GET  /                — list my incoming + outgoing
//   POST /:id/accept      — B accepts; RPC writes user_contacts both ways
//   POST /:id/decline     — B declines; row stays for audit
//   POST /:id/cancel      — A cancels their own pending request
//
// Writes go through service-role; the RLS on friend_requests only exposes
// SELECT to either party. The accept side-effect (symmetric user_contacts
// rows + remark→alias copy) lives in pendingbot.accept_friend_request —
// see migrations 0046 / 0049 / 0061.

export const friendRequestRoutes = new Hono<AppBindings>();
friendRequestRoutes.use('*', requireSession());

const CreateBody = z.object({
  handleValue: z.string().min(4).max(64),
  remark: z.string().max(64).optional(),
});

// Preview a user by handle. Used by the iOS 加好友 page after the user
// finishes typing the number, so they can confirm "this is the person I
// meant" before sending the request. Intentionally returns only the
// display fields — exposing email or created_at here would leak data
// beyond what the recipient consented to via their handle.
friendRequestRoutes.get('/lookup', async (c) => {
  const handleValue = c.req.query('handleValue')?.trim();
  if (!handleValue || handleValue.length < 4 || handleValue.length > 64) {
    return c.json({ error: 'handleValue required' }, 400);
  }
  const supa = serviceClient(c.env);
  const { data: handle, error } = await supa
    .from('user_handles')
    .select('user_id, is_active')
    .eq('value', handleValue)
    .maybeSingle();
  if (error) return c.json({ error: '号码查询失败,请稍后重试', detail: error.message }, 500);
  if (!handle || !handle.is_active) return c.json({ error: '号码无效或已撤销' }, 404);

  const { data: profile, error: profErr } = await supa
    .from('users')
    .select('id, display_name, avatar_path')
    .eq('id', handle.user_id as string)
    .maybeSingle();
  if (profErr) return c.json({ error: 'database', detail: profErr.message }, 500);
  if (!profile) return c.json({ error: '号码无效或已撤销' }, 404);

  return c.json({
    userId: profile.id as string,
    displayName: (profile.display_name as string | null) ?? '',
    avatarPath: (profile.avatar_path as string | null) ?? null,
  });
});

friendRequestRoutes.post('/', async (c) => {
  const userId = c.var.userId!;
  let parsed: z.infer<typeof CreateBody>;
  try {
    parsed = CreateBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supa = serviceClient(c.env);

  const { data: handle, error: handleErr } = await supa
    .from('user_handles')
    .select('id, user_id, is_active')
    .eq('value', parsed.handleValue)
    .maybeSingle();
  if (handleErr) return c.json({ error: '号码查询失败,请稍后重试', detail: handleErr.message }, 500);
  if (!handle || !handle.is_active) return c.json({ error: '号码无效或已撤销' }, 404);
  const targetUserId = handle.user_id as string;
  const viaHandleId = handle.id as string;

  if (targetUserId === userId) return c.json({ error: '不能加自己' }, 400);

  const remark = parsed.remark?.trim() || null;

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
    if (rpcErr) return c.json({ error: '处理对方申请失败,请稍后重试', detail: rpcErr.message }, 500);
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
      remark_for_contact: remark,
      via_handle_id: viaHandleId,
    })
    .select('id')
    .single();
  if (insertErr) {
    if ((insertErr as { code?: string }).code === '23505') {
      return c.json({ error: '已发送过申请,等对方回复' }, 409);
    }
    return c.json({ error: '发送申请失败,请稍后重试', detail: insertErr.message }, 500);
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
  if (error) return c.json({ error: '加载申请列表失败,请稍后重试', detail: error.message }, 500);

  // Attach peer profile (the other side relative to the caller) so iOS
  // can render a name without a follow-up trip per row. Single batched
  // lookup against pendingbot.users.
  const peerIds = Array.from(
    new Set((rows ?? []).map((r) => (r.from_user_id === userId ? r.to_user_id : r.from_user_id))),
  );
  let profilesById: Record<string, { display_name: string; avatar_path: string | null }> = {};
  if (peerIds.length > 0) {
    const { data: profiles } = await supa
      .from('users')
      .select('id, display_name, avatar_path')
      .in('id', peerIds);
    for (const p of profiles ?? []) {
      profilesById[p.id as string] = {
        display_name: (p.display_name as string) ?? '',
        avatar_path: (p.avatar_path as string | null) ?? null,
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
  if (readErr) return c.json({ error: '读取申请失败,请稍后重试', detail: readErr.message }, 500);
  if (!rq) return c.json({ error: '该申请不存在' }, 404);
  if (rq.to_user_id !== userId) return c.json({ error: '不是你的申请' }, 403);
  if (rq.status !== 'pending') return c.json({ error: '该申请已处理' }, 409);

  const { error: rpcErr } = await supa.rpc('accept_friend_request', {
    p_request_id: requestId,
    p_user_id: userId,
  });
  if (rpcErr) return c.json({ error: '接受申请失败,请稍后重试', detail: rpcErr.message }, 500);
  return c.json({ ok: true });
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
  if (error) return c.json({ error: '拒绝申请失败,请稍后重试', detail: error.message }, 500);
  if (!updated || updated.length === 0) {
    return c.json({ error: '申请不存在或已处理' }, 409);
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
  if (error) return c.json({ error: '撤回申请失败,请稍后重试', detail: error.message }, 500);
  if (!updated || updated.length === 0) {
    return c.json({ error: '申请不存在或已处理' }, 409);
  }
  return c.json({ ok: true });
});
