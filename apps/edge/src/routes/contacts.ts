import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
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
contactRoutes.get('/', async (c) => {
  const userId = c.var.userId!;
  const supa = serviceClient(c.env);
  const { data: rows, error } = await supa
    .from('user_contacts')
    .select('contact_user_id, alias, created_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: true });
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  const ids = (rows ?? []).map((r) => r.contact_user_id as string);
  if (ids.length === 0) return c.json({ contacts: [] });

  const { data: profiles, error: profErr } = await supa
    .from('users')
    .select('id, display_name, avatar_path')
    .in('id', ids);
  if (profErr) return c.json({ error: 'database', detail: profErr.message }, 500);
  const byId = new Map<string, { display_name: string | null; avatar_path: string | null }>();
  for (const p of profiles ?? []) {
    byId.set(p.id as string, {
      display_name: (p.display_name as string | null) ?? null,
      avatar_path: (p.avatar_path as string | null) ?? null,
    });
  }
  const contacts = (rows ?? []).map((r) => {
    const p = byId.get(r.contact_user_id as string);
    return {
      userId: r.contact_user_id as string,
      alias: (r.alias as string | null) ?? null,
      displayName: p?.display_name ?? '',
      avatarPath: p?.avatar_path ?? null,
    };
  });
  return c.json({ contacts });
});

// POST /v1/contacts/open-chat — find-or-create the singleton user_user
// conversation between the caller and another user. iOS calls this when
// the user taps a human friend from the friends list; subsequent taps
// resolve to the same conv (per the "人和人之间的会话只能有一个" rule).
const OpenChatBody = z.object({ contactUserId: z.string().uuid() });
contactRoutes.post('/open-chat', async (c) => {
  const userId = c.var.userId!;
  let parsed: z.infer<typeof OpenChatBody>;
  try {
    parsed = OpenChatBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }
  const otherId = parsed.contactUserId;
  if (otherId === userId) return c.json({ error: 'cannot open chat with yourself' }, 400);

  const supa = serviceClient(c.env);

  // Gate: caller must already have the other user as a contact. The
  // friend-request flow writes both user_contacts rows on accept, so
  // this also implicitly proves the other side opted in. iOS surfaces
  // the 403 as a hint to send a friend request first.
  const { data: contact } = await supa
    .from('user_contacts')
    .select('contact_user_id')
    .eq('user_id', userId)
    .eq('contact_user_id', otherId)
    .maybeSingle();
  if (!contact) {
    return c.json({ error: '还不是好友,先发送好友申请' }, 403);
  }

  // Find an existing user_user conv where both users participate. We can
  // do this with two participant-row reads + intersection, but the most
  // efficient single query is: pull all my user_user conv ids, then
  // check which one has the other user as a participant.
  const { data: mine } = await supa
    .from('conversation_participants')
    .select('conversation_id, conversations!inner(conversation_type)')
    .eq('participant_type', 'user')
    .eq('participant_id', userId)
    .eq('conversations.conversation_type', 'user_user');
  const myConvIds = (mine ?? []).map((r) => r.conversation_id as string);
  if (myConvIds.length > 0) {
    const { data: theirs } = await supa
      .from('conversation_participants')
      .select('conversation_id')
      .eq('participant_type', 'user')
      .eq('participant_id', otherId)
      .in('conversation_id', myConvIds);
    const shared = (theirs ?? []).map((r) => r.conversation_id as string)[0];
    if (shared) return c.json({ conversationId: shared, created: false });
  }

  // Not found — create.
  const { data: conv, error: convErr } = await supa
    .from('conversations')
    .insert({
      conversation_type: 'user_user',
      feature: 'message',
      user_id: userId,
      title: null,
    })
    .select('id')
    .single();
  if (convErr || !conv) return c.json({ error: 'database', detail: convErr?.message }, 500);
  const convId = conv.id as string;
  await supa.from('conversation_participants').insert([
    { conversation_id: convId, participant_type: 'user', participant_id: userId, role: 'owner' },
    { conversation_id: convId, participant_type: 'user', participant_id: otherId, role: 'member' },
  ]);
  return c.json({ conversationId: convId, created: true });
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
  if (partsErr) return c.json({ error: 'database', detail: partsErr.message }, 500);
  const ids = (parts ?? []).map((r) => r.participant_id as string);
  if (!ids.includes(userId)) return c.json({ error: 'not a participant' }, 403);
  const otherId = ids.find((id) => id !== userId);
  if (!otherId) return c.json({ error: 'no peer' }, 404);

  // Read the peer's basic profile + the caller's local alias (if any).
  // Both lookups are independent so they fire in parallel.
  const [profileRes, contactRes] = await Promise.all([
    supa.from('users').select('id, display_name, avatar_path').eq('id', otherId).maybeSingle(),
    supa
      .from('user_contacts')
      .select('alias')
      .eq('user_id', userId)
      .eq('contact_user_id', otherId)
      .maybeSingle(),
  ]);
  if (profileRes.error) return c.json({ error: 'database', detail: profileRes.error.message }, 500);

  return c.json({
    userId: otherId,
    displayName: (profileRes.data?.display_name as string | null) ?? '',
    avatarPath: (profileRes.data?.avatar_path as string | null) ?? null,
    alias: (contactRes.data?.alias as string | null) ?? null,
  });
});
