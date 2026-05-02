import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import type { AppBindings } from '../types';

export const contactRoutes = new Hono<AppBindings>();
contactRoutes.use('*', requireSession());

const AddBody = z.object({
  // Either handle code or email; one must be set.
  handleValue: z.string().min(4).max(64).optional(),
  email: z.string().email().optional(),
  alias: z.string().max(80).optional(),
});

// POST /v1/contacts/add — one of:
//   { handleValue: 'A1B2C3' }   add by recipient's shareable code
//   { email: 'foo@bar' }         add by recipient's email
//
// On success: writes BOTH user_contacts rows (the caller's view of the
// other and vice versa) + records which handle was used so each side
// can audit "how did we get connected".
contactRoutes.post('/add', async (c) => {
  const userId = c.var.userId!;
  let parsed: z.infer<typeof AddBody>;
  try {
    parsed = AddBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }
  if (!parsed.handleValue && !parsed.email) {
    return c.json({ error: 'handleValue or email required' }, 400);
  }

  const supa = serviceClient(c.env);
  let targetUserId: string | null = null;
  let handleId: string | null = null;

  if (parsed.handleValue) {
    const { data: handle, error } = await supa
      .from('user_handles')
      .select('id, user_id, is_active')
      .eq('value', parsed.handleValue)
      .maybeSingle();
    if (error) return c.json({ error: 'database', detail: error.message }, 500);
    if (!handle || !handle.is_active) {
      return c.json({ error: '号码无效或已撤销' }, 404);
    }
    targetUserId = handle.user_id as string;
    handleId = handle.id as string;
  } else if (parsed.email) {
    // Look up by email via the Auth admin API. supabase-js doesn't expose
    // /auth/v1/admin/users?email so we hit it directly.
    const url = new URL('/auth/v1/admin/users', c.env.SUPABASE_URL);
    url.searchParams.set('email', parsed.email);
    const res = await fetch(url, {
      headers: {
        apikey: c.env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${c.env.SUPABASE_SERVICE_ROLE_KEY}`,
      },
    });
    if (!res.ok) {
      return c.json({ error: 'lookup failed', status: res.status }, 500);
    }
    const body = (await res.json()) as { users?: Array<{ id: string; email?: string }> };
    const match = (body.users ?? []).find(
      (u) => (u.email ?? '').toLowerCase() === parsed.email!.toLowerCase(),
    );
    if (!match) return c.json({ error: '没找到这个邮箱注册的用户' }, 404);
    targetUserId = match.id;
  }

  if (!targetUserId) return c.json({ error: 'lookup failed' }, 500);
  if (targetUserId === userId) return c.json({ error: '不能加自己' }, 400);

  // Symmetric upsert: A→B with the alias the caller chose; B→A with no
  // alias yet (B can rename later). Both rows reference the same handle
  // for audit ("X added me via handle 'blog'").
  const { error: insertErr } = await supa
    .from('user_contacts')
    .upsert(
      [
        {
          user_id: userId,
          contact_user_id: targetUserId,
          added_via_handle_id: handleId,
          alias: parsed.alias ?? null,
        },
        {
          user_id: targetUserId,
          contact_user_id: userId,
          added_via_handle_id: handleId,
          alias: null,
        },
      ],
      { onConflict: 'user_id,contact_user_id', ignoreDuplicates: true },
    );
  if (insertErr) return c.json({ error: 'database', detail: insertErr.message }, 500);

  return c.json({ ok: true, contactUserId: targetUserId });
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
