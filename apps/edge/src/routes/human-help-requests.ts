import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

export const humanHelpRequestRoutes = new Hono<AppBindings>();
humanHelpRequestRoutes.use('*', requireSession());

function rpcMessage(err: unknown): string {
  if (typeof err === 'string') return err;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return err == null ? 'database error' : String(err);
}

humanHelpRequestRoutes.get('/', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const status = c.req.query('status') ?? 'pending';
  const supa = userClient(c.env, userJwt);

  const { data: requests, error } = await supa
    .from('human_help_requests')
    .select('id, temporary_group_id, requester_member_id, requested_user_id, responsible_subject_id, status, reason, created_at, decided_at')
    .eq('requested_user_id', userId)
    .eq('status', status)
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });

  const rows = requests ?? [];
  const convIds = [...new Set(rows.map((r) => r.temporary_group_id))];
  const requesterIds = [...new Set(rows.map((r) => r.requester_member_id))];
  const svc = serviceClient(c.env);
  const [{ data: metas }, { data: convs }, { data: requesters }] = await Promise.all([
    convIds.length
      ? svc.from('temporary_group_meta').select('conversation_id, title, temporary_kind, status').in('conversation_id', convIds)
      : { data: [] },
    convIds.length
      ? svc.from('conversations').select('id, title').in('id', convIds)
      : { data: [] },
    requesterIds.length
      ? svc.from('temporary_group_members').select('id, display_name, member_kind').in('id', requesterIds)
      : { data: [] },
  ]);

  const metaByConv = new Map((metas ?? []).map((m) => [m.conversation_id, m]));
  const convById = new Map((convs ?? []).map((conv) => [conv.id, conv]));
  const requesterById = new Map((requesters ?? []).map((member) => [member.id, member]));

  return c.json({
    items: rows.map((request) => {
      const meta = metaByConv.get(request.temporary_group_id);
      const conv = convById.get(request.temporary_group_id);
      const requester = requesterById.get(request.requester_member_id);
      return {
        id: request.id,
        temporary_group_id: request.temporary_group_id,
        responsible_subject_id: request.responsible_subject_id,
        status: request.status,
        reason: request.reason,
        created_at: request.created_at,
        decided_at: request.decided_at,
        temporary_group: {
          title: meta?.title ?? conv?.title ?? '临时群',
          temporary_kind: meta?.temporary_kind ?? null,
          status: meta?.status ?? null,
        },
        requester: requester
          ? {
            id: requester.id,
            display_name: requester.display_name,
            member_kind: requester.member_kind,
          }
          : null,
      };
    }),
  });
});

const DecisionBody = z.object({
  decision: z.enum(['accepted', 'declined']),
});

humanHelpRequestRoutes.post('/:id/decision', async (c) => {
  const userJwt = c.var.userJwt!;
  const requestId = c.req.param('id');
  let parsed: z.infer<typeof DecisionBody>;
  try {
    parsed = DecisionBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = userClient(c.env, userJwt);
  const { data, error } = await supa.rpc('decide_human_help_request', {
    p_request_id: requestId,
    p_decision: parsed.decision,
  });
  if (error) {
    const message = rpcMessage(error);
    if (/auth required/i.test(message)) return jsonError(c, 401, 'unauthorized', { message });
    if (/forbidden|not yours/i.test(message)) return jsonError(c, 403, 'forbidden', { message });
    if (/not found/i.test(message)) return jsonError(c, 404, 'not_found', { message });
    if (/invalid|already decided/i.test(message)) return jsonError(c, 400, 'invalid_body', { message });
    return jsonError(c, 500, 'database_error', { detail: message });
  }

  return c.json({ ok: data === true });
});

