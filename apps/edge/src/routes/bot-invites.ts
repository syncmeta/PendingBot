import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import { rateLimitOrBlock } from '../lib/rate-limit';
import type { AppBindings } from '../types';

// Token-keyed invite endpoints (decisions.md D1). The bot's slug is NOT a join
// path anymore — joining goes through an inviter-scoped token. Resolution and
// redemption run through SECURITY DEFINER RPCs that bind to auth.uid(); the
// `bots` / `user_bot_contacts` RLS stays strict (redeem writes the bot_invites
// grant row itself).
export const botInviteRoutes = new Hono<AppBindings>();
botInviteRoutes.use('*', requireSession());

// 64 hex chars (two concatenated uuids, dashes stripped). Matches the token
// minted by bot_invite_link_create.
const TOKEN_RE = /^[a-f0-9]{64}$/;

// GET /v1/bot-invites/:token — preview the bot behind an invite link, for the
// "add bot" confirmation page. Enumerable-ish (token is unguessable, but gate
// it with the same limiter as handle lookups for defense in depth).
botInviteRoutes.get('/:token', async (c) => {
  const blocked = await rateLimitOrBlock(c, c.env.HANDLE_LOOKUP_RL);
  if (blocked) return blocked;

  const token = c.req.param('token');
  if (!TOKEN_RE.test(token)) return jsonError(c, 400, 'invalid_id');

  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('bot_invite_link_resolve', { p_token: token });
  if (error) {
    if (/无效|已撤销|已过期/.test(error.message)) {
      return jsonError(c, 404, 'not_found', { message: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const row = (data ?? [])[0] as
    | {
        bot_id: string;
        display_name: string;
        slug: string | null;
        model_id: string | null;
        visibility: string | null;
        inviter_name: string | null;
      }
    | undefined;
  if (!row) return jsonError(c, 404, 'not_found', { message: '邀请链接无效' });
  return c.json({
    botId: row.bot_id,
    displayName: row.display_name,
    slug: row.slug,
    modelId: row.model_id,
    visibility: row.visibility,
    inviterName: row.inviter_name,
  });
});

// POST /v1/bot-invites/:token/redeem — accept the invite: grant the bot to the
// caller + record who invited them. Idempotent.
botInviteRoutes.post('/:token/redeem', async (c) => {
  const token = c.req.param('token');
  if (!TOKEN_RE.test(token)) return jsonError(c, 400, 'invalid_id');

  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('bot_invite_link_redeem', { p_token: token });
  if (error) {
    if (/无效|已撤销|已过期/.test(error.message)) {
      return jsonError(c, 404, 'not_found', { message: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ botId: data as unknown as string });
});

// DELETE /v1/bot-invites/:token — revoke a link you minted (or, for the bot
// creator, any link on your bot).
botInviteRoutes.delete('/:token', async (c) => {
  const token = c.req.param('token');
  if (!TOKEN_RE.test(token)) return jsonError(c, 400, 'invalid_id');

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('bot_invite_link_revoke', { p_token: token });
  if (error) {
    if (/签发者|创建者/.test(error.message)) {
      return jsonError(c, 403, 'forbidden', { detail: error.message });
    }
    if (/不存在/.test(error.message)) {
      return jsonError(c, 404, 'not_found', { detail: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ ok: true });
});
