import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { UUID_RE } from '../lib/ids';
import { jsonError } from '../lib/http-error';
import { findSharedUserUserConversation } from '../lib/route-authz';
import type { AppBindings } from '../types';

export const contactRoutes = new Hono<AppBindings>();
contactRoutes.use('*', requireSession());

// POST /v1/contacts/add is gone — adding a human now goes through the
// friend-request flow. iOS calls POST /v1/friend-requests directly.
// (Kept the import + AddBody schema below intentionally absent so any
// straggler client gets a clean 404 instead of silently writing the old
// symmetric-upsert path.)

// GET /v1/contacts — full friends list with peer display info. RLS on
// pendingbot.users is self-only, so iOS can't join from user_contacts to
// users client-side; the worker uses service-role to attach
// display_name + avatar_path for each contact in one trip. Drives both
// the friends tab and the message-list peer lookup for user_user convs.
//
// Optional `?via_handle_id=<uuid>` narrows the list to contacts who
// added the caller via that specific handle (drives the per-handle
// friend list in 加我为好友的方式 → 我的隐私号 detail view).
contactRoutes.get('/', async (c) => {
  const userId = c.var.userId!;
  const viaHandleId = c.req.query('via_handle_id') ?? null;
  const supa = serviceClient(c.env);
  let query = supa
    .from('user_contacts')
    .select('contact_user_id, alias, created_at, added_via_handle_id')
    .eq('user_id', userId)
    .order('created_at', { ascending: true });
  if (viaHandleId) {
    query = query.eq('added_via_handle_id', viaHandleId);
  }
  const { data: rows, error } = await query;
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  const ids = (rows ?? []).map((r) => r.contact_user_id as string);
  if (ids.length === 0) return c.json({ contacts: [] });

  const { data: profiles, error: profErr } = await supa
    .from('users')
    .select('id, display_name, avatar_path, custom_fields')
    .in('id', ids);
  if (profErr) return jsonError(c, 500, 'database_error', { detail: profErr.message });
  const byId = new Map<string, {
    display_name: string | null;
    avatar_path: string | null;
    avatar_seed: string;
  }>();
  for (const p of profiles ?? []) {
    byId.set(p.id as string, {
      display_name: (p.display_name as string | null) ?? null,
      avatar_path: (p.avatar_path as string | null) ?? null,
      avatar_seed: extractAvatarSeed(p.custom_fields, p.id as string),
    });
  }
  const contacts = (rows ?? []).map((r) => {
    const p = byId.get(r.contact_user_id as string);
    return {
      userId: r.contact_user_id as string,
      alias: (r.alias as string | null) ?? null,
      displayName: p?.display_name ?? '',
      avatarPath: p?.avatar_path ?? null,
      avatarSeed: p?.avatar_seed ?? (r.contact_user_id as string),
      // Friend-added time as epoch seconds — drives the "按加好友时间"
      // sort option in the friends list. 0 when the timestamp is somehow
      // missing/unparseable so the client still has a stable key.
      addedAt: epochSeconds(r.created_at as string | null),
    };
  });
  return c.json({ contacts });
});

// Postgres timestamptz → Unix epoch seconds. Returns 0 when the value is
// null or unparseable so the client always gets a numeric sort key.
function epochSeconds(ts: string | null): number {
  if (!ts) return 0;
  const ms = Date.parse(ts);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0;
}

// custom_fields.avatar_seed is the UUID the user picked during onboarding
// (ProfileBootstrapView "shuffle" loop). It's the only source of truth for
// the placeholder-emoji seed across clients — without it, every client
// would hash a different field (their own UUID locally vs the contact's
// user_id remotely) and the same person would render with different emoji
// on different devices. Falls back to user_id so legacy users who never
// bootstrapped still get *some* deterministic emoji.
function extractAvatarSeed(customFields: unknown, userId: string): string {
  if (customFields && typeof customFields === 'object') {
    const seed = (customFields as Record<string, unknown>).avatar_seed;
    if (typeof seed === 'string' && seed.length > 0) return seed;
  }
  return userId;
}

// POST /v1/contacts/open-chat — find-or-create the singleton user_user
// conversation between the caller and another user. iOS calls this when
// the user taps a human friend from the friends list; subsequent taps
// resolve to the same conv (per the "人和人之间的会话只能有一个" rule).
const OpenChatBody = z.object({ contactUserId: z.string().uuid() });
contactRoutes.post('/open-chat', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  let parsed: z.infer<typeof OpenChatBody>;
  try {
    parsed = OpenChatBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const otherId = parsed.contactUserId;
  if (otherId === userId) return jsonError(c, 400, 'self_chat_not_allowed', { message: 'cannot open chat with yourself' });

  const supaUser = userClient(c.env, userJwt);
  const { data, error } = await supaUser.rpc('open_user_user_conv', {
    p_other_user_id: otherId,
  });
  if (error) {
    if (/not contacts/i.test(error.message)) {
      return jsonError(c, 403, 'forbidden', { message: '还不是好友,先发送好友申请' });
    }
    if (/auth required|cannot open self/i.test(error.message)) {
      return jsonError(c, 400, 'invalid_body', { detail: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }

  const payload = data as { conversationId?: string; created?: boolean } | null;
  if (!payload?.conversationId) {
    return jsonError(c, 500, 'database_error', { detail: 'open_user_user_conv returned malformed payload' });
  }
  return c.json({
    conversationId: payload.conversationId,
    created: payload.created === true,
  });
});

// POST /v1/contacts/profiles — bulk profile lookup gated on shared
// conversation membership. iOS uses this for the group-members sheet
// and the group-bubble sender labels: pendingbot.users RLS is self-only,
// so a direct select from the client returns empty for every other user
// and the UI falls back to id-prefix. Routing through the worker with a
// service-role read fills in display_name + avatar_path + avatar_seed
// for everyone the caller actually shares a conv with.
//
// Gate: every requested userId must be a participant of conversationId,
// and so must the caller. Anything else returns 403 — no fishing.
const ProfilesBody = z.object({
  conversationId: z.string().uuid(),
  userIds: z.array(z.string().uuid()).min(1).max(100),
});
contactRoutes.post('/profiles', async (c) => {
  const userId = c.var.userId!;
  let parsed: z.infer<typeof ProfilesBody>;
  try {
    parsed = ProfilesBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = serviceClient(c.env);
  const ids = Array.from(new Set([userId, ...parsed.userIds]));
  const { data: parts, error: partsErr } = await supa
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', parsed.conversationId)
    .eq('participant_type', 'user')
    .in('participant_id', ids);
  if (partsErr) return jsonError(c, 500, 'database_error', { detail: partsErr.message });
  const participantIds = new Set((parts ?? []).map((r) => r.participant_id as string));
  if (!participantIds.has(userId)) {
    return jsonError(c, 403, 'not_a_participant');
  }
  const requested = parsed.userIds.filter((id) => participantIds.has(id));
  if (requested.length === 0) return c.json({ profiles: [] });

  const { data: users, error: usersErr } = await supa
    .from('users')
    .select('id, display_name, avatar_path, custom_fields')
    .in('id', requested);
  if (usersErr) return jsonError(c, 500, 'database_error', { detail: usersErr.message });

  const profiles = (users ?? []).map((u) => ({
    userId: u.id as string,
    displayName: (u.display_name as string | null) ?? '',
    avatarPath: (u.avatar_path as string | null) ?? null,
    avatarSeed: extractAvatarSeed(u.custom_fields, u.id as string),
  }));
  return c.json({ profiles });
});

// PATCH /v1/contacts/:contactUserId — update the caller's local alias
// for a contact (WeChat-style 备注). Empty string clears the alias and
// the friend reverts to displaying their own display_name. Doesn't change
// anything on the contact's side — they keep whatever alias (or none)
// they set for the caller independently.
const AliasBody = z.object({ alias: z.string().max(64).nullable() });
contactRoutes.patch('/:contactUserId', async (c) => {
  const userId = c.var.userId!;
  const contactUserId = c.req.param('contactUserId');
  if (!UUID_RE.test(contactUserId)) {
    return jsonError(c, 400, 'invalid_id');
  }
  let parsed: z.infer<typeof AliasBody>;
  try {
    parsed = AliasBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const trimmed = parsed.alias?.trim();
  const aliasValue = trimmed && trimmed.length > 0 ? trimmed : null;

  const supa = serviceClient(c.env);
  const { data, error } = await supa
    .from('user_contacts')
    .update({ alias: aliasValue })
    .eq('user_id', userId)
    .eq('contact_user_id', contactUserId)
    .select('contact_user_id');
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  if (!data || data.length === 0) {
    return jsonError(c, 404, 'not_found', { message: '不是好友,无法设置备注' });
  }
  return c.json({ ok: true, alias: aliasValue });
});

// POST /v1/contacts/:contactUserId/mute — toggle the caller's mute flag
// for the singleton user_user conv between caller and this contact.
// Mute lives on conversation_participants.muted (set on caller's row only,
// so each side mutes independently). The conv is materialised lazily on
// first chat; the worker creates the row here when missing so the toggle
// always has somewhere to land.
const MuteBody = z.object({ muted: z.boolean() });
contactRoutes.post('/:contactUserId/mute', async (c) => {
  const userId = c.var.userId!;
  const contactUserId = c.req.param('contactUserId');
  if (!UUID_RE.test(contactUserId)) return jsonError(c, 400, 'invalid_id');
  let parsed: z.infer<typeof MuteBody>;
  try {
    parsed = MuteBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = serviceClient(c.env);

  // Friendship gate — same as open-chat. Stops a stale alias from being
  // used to flip a participant row in a conv the caller no longer shares.
  const { data: contact } = await supa
    .from('user_contacts')
    .select('contact_user_id')
    .eq('user_id', userId)
    .eq('contact_user_id', contactUserId)
    .maybeSingle();
  if (!contact) return jsonError(c, 403, 'forbidden', { message: '还不是好友' });

  const shared = await findSharedUserUserConversation(c.env, userId, contactUserId);
  if (!shared.ok) return jsonError(c, 500, 'database_error', { detail: shared.detail });
  if (!shared.conversationId) return c.json({ ok: true, muted: parsed.muted });

  const { error } = await supa
    .from('conversation_participants')
    .update({ muted: parsed.muted })
    .eq('conversation_id', shared.conversationId)
    .eq('participant_type', 'user')
    .eq('participant_id', userId);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ ok: true, muted: parsed.muted });
});

// GET /v1/contacts/:contactUserId — return whether caller has muted this
// contact's user_user conv. Used by the 1v1 settings page to seed the
// 免打扰 toggle.
contactRoutes.get('/:contactUserId', async (c) => {
  const userId = c.var.userId!;
  const contactUserId = c.req.param('contactUserId');
  if (!UUID_RE.test(contactUserId)) return jsonError(c, 400, 'invalid_id');

  const supa = serviceClient(c.env);
  const { data: contact } = await supa
    .from('user_contacts')
    .select('alias')
    .eq('user_id', userId)
    .eq('contact_user_id', contactUserId)
    .maybeSingle();
  if (!contact) return jsonError(c, 404, 'not_found', { message: '不是好友' });

  // Look up the conv and read the caller's muted flag.
  // Missing conv → default false; the row gets created on first chat.
  const shared = await findSharedUserUserConversation(c.env, userId, contactUserId);
  if (!shared.ok) return jsonError(c, 500, 'database_error', { detail: shared.detail });
  let muted = false;
  if (shared.conversationId) {
    const { data: myRow } = await supa
      .from('conversation_participants')
      .select('muted')
      .eq('conversation_id', shared.conversationId)
      .eq('participant_type', 'user')
      .eq('participant_id', userId)
      .maybeSingle();
    muted = Boolean(myRow?.muted);
  }
  return c.json({
    contactUserId,
    alias: (contact.alias as string | null) ?? null,
    muted,
  });
});

// DELETE /v1/contacts/:contactUserId — 删除好友. Drops user_contacts rows
// in both directions so neither side ends up holding a stale half-edge
// (which would let one party still hit /open-chat). The shared user_user
// conv is removed too, so messages, attachments, participants etc. fall
// away via cascade. audit_log rows reference the conv without CASCADE, so
// null those out first or the DELETE would error.
contactRoutes.delete('/:contactUserId', async (c) => {
  const userId = c.var.userId!;
  const contactUserId = c.req.param('contactUserId');
  if (!UUID_RE.test(contactUserId)) return jsonError(c, 400, 'invalid_id');

  const supa = serviceClient(c.env);

  // Drop both directions in one statement so a transient failure between
  // the two writes can't leave a half-edge.
  const { error: deleteErr } = await supa
    .from('user_contacts')
    .delete()
    .or(
      `and(user_id.eq.${userId},contact_user_id.eq.${contactUserId}),` +
      `and(user_id.eq.${contactUserId},contact_user_id.eq.${userId})`,
    );
  if (deleteErr) return jsonError(c, 500, 'database_error', { detail: deleteErr.message });

  const shared = await findSharedUserUserConversation(c.env, userId, contactUserId);
  if (!shared.ok) return jsonError(c, 500, 'database_error', { detail: shared.detail });
  if (shared.conversationId) {
    // audit_log FK has no CASCADE — null its conversation_id first so
    // the DELETE on conversations doesn't trip the constraint.
    await supa
      .from('audit_log')
      .update({ conversation_id: null })
      .eq('conversation_id', shared.conversationId);
    const { error: convErr } = await supa
      .from('conversations')
      .delete()
      .eq('id', shared.conversationId);
    if (convErr) return jsonError(c, 500, 'database_error', { detail: convErr.message });
  }

  return c.json({ ok: true });
});

// GET /v1/contacts/conv-peer/:convId — resolve the other user's display
// info for a user_user conversation. Caller must already be a participant
// (RLS on `pendingbot.users` is self-only, so iOS can't read this directly
// even though it's their own peer). Returns the peer's display_name +
// avatar_path along with the caller's local alias for them, if any.
contactRoutes.get('/conv-peer/:convId', async (c) => {
  const userId = c.var.userId!;
  const convId = c.req.param('convId');

  const supa = serviceClient(c.env);

  // Verify the conv is user_user and the caller is a participant. One
  // round-trip via a join: pull both participant rows for the conv,
  // gated by conversation_type, then check membership client-side.
  const { data: parts, error: partsErr } = await supa
    .from('conversation_participants')
    .select('participant_type, participant_id, conversations!inner(conversation_type)')
    .eq('conversation_id', convId)
    .eq('participant_type', 'user')
    .eq('conversations.conversation_type', 'user_user');
  if (partsErr) return jsonError(c, 500, 'database_error', { detail: partsErr.message });
  const ids = (parts ?? []).map((r) => r.participant_id as string);
  if (!ids.includes(userId)) return jsonError(c, 403, 'not_a_participant');
  const otherId = ids.find((id) => id !== userId);
  if (!otherId) return jsonError(c, 404, 'peer_not_found');

  // Read the peer's basic profile + the caller's local alias (if any).
  // Both lookups are independent so they fire in parallel.
  const [profileRes, contactRes] = await Promise.all([
    supa.from('users').select('id, display_name, avatar_path, custom_fields').eq('id', otherId).maybeSingle(),
    supa
      .from('user_contacts')
      .select('alias')
      .eq('user_id', userId)
      .eq('contact_user_id', otherId)
      .maybeSingle(),
  ]);
  if (profileRes.error) return jsonError(c, 500, 'database_error', { detail: profileRes.error.message });

  return c.json({
    userId: otherId,
    displayName: (profileRes.data?.display_name as string | null) ?? '',
    avatarPath: (profileRes.data?.avatar_path as string | null) ?? null,
    avatarSeed: extractAvatarSeed(profileRes.data?.custom_fields, otherId),
    alias: (contactRes.data?.alias as string | null) ?? null,
  });
});
