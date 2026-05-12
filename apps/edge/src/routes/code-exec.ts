import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

// POST /v1/code-exec-requests/:id/respond
//
// Companion to the bot's request_execute_code tool. The bot creates a
// pending row in bot_code_exec_requests, the iOS app shows an approval
// card with two buttons, and a tap POSTs here to flip the row's status.
// The bot-reply turn that's polling that row sees the change within
// ~500ms and either runs the code (approved) or returns the decision
// to the model (denied).
//
// Race / replay safety:
//   - Service role bypasses RLS; we ownership-check user_id explicitly.
//   - Status update is guarded `eq('status','pending')` so a late POST
//     after timeout/already-decided doesn't clobber a resolved request.

export const codeExecRoutes = new Hono<AppBindings>();
codeExecRoutes.use('*', requireSession());

const RespondBody = z.object({
  decision: z.enum(['approve', 'deny']),
});

codeExecRoutes.post('/:id/respond', async (c) => {
  const userId = c.var.userId!;
  const id = c.req.param('id');

  let parsed: z.infer<typeof RespondBody>;
  try {
    parsed = RespondBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supa = serviceClient(c.env);

  // Look up + ownership check. Don't reveal existence of someone else's
  // request — 404 covers both "doesn't exist" and "not yours".
  const { data: row, error: readErr } = await supa
    .from('bot_code_exec_requests')
    .select('id, user_id, status')
    .eq('id', id)
    .maybeSingle();
  if (readErr) return jsonError(c, 500, 'database_error', { detail: readErr.message });
  if (!row) return jsonError(c, 404, 'not_found');
  const r = row as { id: string; user_id: string; status: string };
  if (r.user_id !== userId) return jsonError(c, 404, 'not_found');

  // If the request already resolved (timeout, prior tap), tell iOS the
  // current state so the card can dismiss itself without flipping again.
  if (r.status !== 'pending') {
    return c.json({ ok: true, status: r.status, already_resolved: true });
  }

  const newStatus = parsed.decision === 'approve' ? 'approved' : 'denied';
  const { error: updErr } = await supa
    .from('bot_code_exec_requests')
    .update({ status: newStatus, responded_at: new Date().toISOString() })
    .eq('id', id)
    .eq('status', 'pending');
  if (updErr) return jsonError(c, 500, 'database_error', { detail: updErr.message });

  return c.json({ ok: true, status: newStatus });
});
