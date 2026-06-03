import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { userClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import { rateLimitOrBlock } from '../lib/rate-limit';
import { UUID_RE } from '../lib/ids';
import { trackEvent, AnalyticsEvent } from '../lib/track';
import type { AppBindings } from '../types';

// Per-inviter group invite links (decisions.md D2). Mirrors the bot invite
// model: every member mints their own reusable, revocable token to the same
// group; joining records invited_by. All access via SECURITY DEFINER RPCs
// (RLS on group_invite_links stays closed). See migration 20260601082502.

const TOKEN_RE = /^[a-f0-9]{64}$/;

// Mounted at /v1/groups — the /:id/invite-links management endpoints.
export const groupInviteLinkRoutes = new Hono<AppBindings>();
groupInviteLinkRoutes.use('*', requireSession());

// POST /v1/groups/:id/invite-links — mint a link (caller must be a member).
groupInviteLinkRoutes.post('/:id/invite-links', async (c) => {
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('group_invite_link_create', {
    p_conversation_id: id,
  });
  if (error) {
    if (/群成员/.test(error.message)) {
      return jsonError(c, 403, 'forbidden', { detail: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const row = (data ?? [])[0] as { token: string; expires_at: string } | undefined;
  if (!row) return jsonError(c, 500, 'database_error', { message: '链接生成失败' });
  return c.json({ token: row.token, expiresAt: row.expires_at });
});

// GET /v1/groups/:id/invite-links — the caller's own active links.
groupInviteLinkRoutes.get('/:id/invite-links', async (c) => {
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('group_invite_links_list', {
    p_conversation_id: id,
  });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  const rows = (data ?? []) as Array<{
    token: string;
    created_at: string;
    expires_at: string;
    revoked_at: string | null;
  }>;
  return c.json({
    links: rows.map((r) => ({
      token: r.token,
      createdAt: r.created_at,
      expiresAt: r.expires_at,
      revokedAt: r.revoked_at,
    })),
  });
});

// Mounted at /v1/group-invites — token-keyed resolve / redeem / revoke.
export const groupInviteTokenRoutes = new Hono<AppBindings>();
groupInviteTokenRoutes.use('*', requireSession());

// GET /v1/group-invites/:token — preview the group behind an invite link.
groupInviteTokenRoutes.get('/:token', async (c) => {
  const blocked = await rateLimitOrBlock(c, c.env.HANDLE_LOOKUP_RL);
  if (blocked) return blocked;

  const token = c.req.param('token');
  if (!TOKEN_RE.test(token)) return jsonError(c, 400, 'invalid_id');

  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('group_invite_link_resolve', { p_token: token });
  if (error) {
    if (/无效|已撤销|已过期/.test(error.message)) {
      return jsonError(c, 404, 'not_found', { message: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const row = (data ?? [])[0] as
    | {
        conversation_id: string;
        title: string | null;
        member_count: number;
        join_policy: string;
        inviter_name: string | null;
      }
    | undefined;
  if (!row) return jsonError(c, 404, 'not_found', { message: '邀请链接无效' });
  return c.json({
    conversationId: row.conversation_id,
    title: row.title,
    memberCount: row.member_count,
    joinPolicy: row.join_policy,
    inviterName: row.inviter_name,
  });
});

// POST /v1/group-invites/:token/redeem — join (scan_open) or file a request
// (approval). Records invited_by either way.
groupInviteTokenRoutes.post('/:token/redeem', async (c) => {
  const token = c.req.param('token');
  if (!TOKEN_RE.test(token)) return jsonError(c, 400, 'invalid_id');

  let message = '';
  try {
    const body = (await c.req.json()) as { message?: unknown };
    if (typeof body?.message === 'string') message = body.message.slice(0, 500);
  } catch {
    // no body / not json — fine, message stays empty
  }

  const supa = userClient(c.env, c.var.userJwt!);
  const { data, error } = await supa.rpc('group_invite_link_redeem', {
    p_token: token,
    p_message: message,
  });
  if (error) {
    if (/无效|已撤销|已过期/.test(error.message)) {
      return jsonError(c, 404, 'not_found', { message: error.message });
    }
    if (/closed|full/.test(error.message)) {
      return jsonError(c, 409, 'conflict', { detail: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  const row = (data ?? [])[0] as
    | { conversation_id: string; request_id: string | null; joined: boolean }
    | undefined;
  if (!row) return jsonError(c, 500, 'database_error', { message: '加入失败' });
  if (row.joined) {
    trackEvent(c, AnalyticsEvent.GroupJoined, {
      group_id: row.conversation_id,
      via: 'invite_link',
    });
  }
  return c.json({
    conversationId: row.conversation_id,
    requestId: row.request_id,
    joined: row.joined,
  });
});

// DELETE /v1/group-invites/:token — revoke a link (inviter or group owner/admin).
groupInviteTokenRoutes.delete('/:token', async (c) => {
  const token = c.req.param('token');
  if (!TOKEN_RE.test(token)) return jsonError(c, 400, 'invalid_id');

  const supa = userClient(c.env, c.var.userJwt!);
  const { error } = await supa.rpc('group_invite_link_revoke', { p_token: token });
  if (error) {
    if (/签发者|管理员/.test(error.message)) {
      return jsonError(c, 403, 'forbidden', { detail: error.message });
    }
    if (/不存在/.test(error.message)) {
      return jsonError(c, 404, 'not_found', { detail: error.message });
    }
    return jsonError(c, 500, 'database_error', { detail: error.message });
  }
  return c.json({ ok: true });
});
