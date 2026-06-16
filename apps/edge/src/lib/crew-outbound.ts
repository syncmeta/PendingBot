// Phase 2 — outbound @ + reply_to resolution for session/bot posts to a crew.
//
// The HTTP endpoint (POST /v1/sessions/:sessionId/post-to-crew) uses this to
// translate the spec-v2 `mentions` shape + an optional `reply_to`
// message id into the explicit recipient lists the
// create_crew_announcement[_from_runner]_for_subject RPCs understand
// (p_recipient_session_ids / p_recipient_member_ids), plus the set of session
// ids that should additionally get a directed mailbox row.
//
// `reply_to` auto-@s the replied-to message's original sender:
//   * role 'user'/'human' with user_id → resolve the crew member for that
//     user_id and add it as a *member* recipient (humans have no mailbox, so
//     this is metadata-only fan-out — it does NOT enqueue a mailbox row).
//   * role 'log' with log_payload.session_id → add that session as a *session*
//     recipient (gets a mailbox row, same as an explicit @session).
//
// This keeps the two call sites byte-for-byte aligned (no copy-paste) and
// returns a validation error for malformed @ / reply_to so the caller can map
// it to a 400 (HTTP) or an error envelope (tool).

import type { Env } from '../types';
import { serviceClient } from './supabase';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** One mention as the spec-v2 @ UI emits it. `kind` 'captain'/'broadcast' are
 * not meaningful for *outbound* posts (a session/bot doesn't @ the captain via
 * this path), so we only act on 'session' (mailbox target) and 'human'
 * (metadata-only — humans have no mailbox). Unknown kinds are ignored. */
export interface OutboundMention {
  kind: string;
  target_id?: string;
}

export interface OutboundRecipients {
  /** Explicit session targets → p_recipient_session_ids + mailbox enqueue. */
  sessionIds: string[];
  /** Member targets (e.g. a human auto-@d via reply_to) → p_recipient_member_ids.
   * Members do NOT get a mailbox row. */
  memberIds: string[];
  /** Validated reply_to id, for the mirror message's log_payload.in_reply_to.
   * null when no reply_to was given. */
  inReplyTo: string | null;
  /** Set on a validation failure (bad uuid, missing target_id, reply_to points
   * at a non-existent message). Callers map this to a 400 / error envelope. */
  error?: { status: number; message: string };
}

type MaybeMention = { kind?: unknown; target_id?: unknown };

/** Tolerantly coerce raw tool/body args into OutboundMention[]. Drops anything
 * that isn't an object with a string `kind`. */
export function coerceMentions(raw: unknown): OutboundMention[] {
  if (!Array.isArray(raw)) return [];
  const out: OutboundMention[] = [];
  for (const m of raw) {
    if (m && typeof m === 'object') {
      const mm = m as MaybeMention;
      if (typeof mm.kind === 'string') {
        out.push({
          kind: mm.kind,
          target_id: typeof mm.target_id === 'string' ? mm.target_id : undefined,
        });
      }
    }
  }
  return out;
}

/**
 * Resolve outbound recipients for a session/bot post.
 *
 * @param env       worker env (for the service-role supabase client)
 * @param crewId    crew conversation id (== crew_conversation_id)
 * @param mentions  spec-v2 mention list (already coerced)
 * @param replyTo   optional message id the post is replying to (raw, validated here)
 */
export async function resolveOutboundRecipients(
  env: Env,
  crewId: string,
  mentions: OutboundMention[],
  replyTo: string | null | undefined,
): Promise<OutboundRecipients> {
  const sessionIds = new Set<string>();
  const memberIds = new Set<string>();

  // 1) Explicit mentions. 'session' → mailbox target (needs target_id). 'human'
  //    on an outbound post is metadata-only and has no member id to resolve
  //    here, so we ignore it (the reply_to path is what pulls a human in as a
  //    member recipient). Unknown / captain / broadcast kinds: ignore.
  for (const m of mentions) {
    if (m.kind === 'session') {
      if (!m.target_id || !UUID_RE.test(m.target_id)) {
        return {
          sessionIds: [],
          memberIds: [],
          inReplyTo: null,
          error: { status: 400, message: 'session mention requires a valid target_id' },
        };
      }
      sessionIds.add(m.target_id);
    }
  }

  // 2) reply_to → auto-@ the original sender.
  let inReplyTo: string | null = null;
  if (replyTo != null && replyTo !== '') {
    if (!UUID_RE.test(replyTo)) {
      return {
        sessionIds: [],
        memberIds: [],
        inReplyTo: null,
        error: { status: 400, message: 'reply_to must be a uuid' },
      };
    }
    const svc = serviceClient(env);
    const { data: replied, error: repliedErr } = await svc
      .from('messages')
      .select('id, conversation_id, role, user_id, log_payload')
      .eq('id', replyTo)
      .eq('conversation_id', crewId)
      .maybeSingle();
    if (repliedErr) {
      return {
        sessionIds: [],
        memberIds: [],
        inReplyTo: null,
        error: { status: 500, message: repliedErr.message },
      };
    }
    if (!replied) {
      return {
        sessionIds: [],
        memberIds: [],
        inReplyTo: null,
        error: { status: 400, message: 'reply_to points at a message that does not exist in this crew' },
      };
    }
    inReplyTo = replyTo;

    const role = replied.role as string | null;
    if (role === 'user' || role === 'human') {
      // Human sender → resolve their crew member row (metadata-only recipient,
      // no mailbox). If the user_id isn't an active member we silently drop the
      // auto-@ — the post still lands, just without the member fan-out.
      const userId = replied.user_id as string | null;
      if (userId) {
        const { data: mem } = await svc
          .from('temporary_group_members')
          .select('id')
          .eq('conversation_id', crewId)
          .eq('user_id', userId)
          .eq('status', 'active')
          .maybeSingle();
        if (mem?.id) memberIds.add(mem.id as string);
      }
    } else if (role === 'log') {
      // Session post → auto-@ that session (gets a mailbox row).
      const lp = (replied.log_payload ?? {}) as Record<string, unknown>;
      const sid = typeof lp.session_id === 'string' ? lp.session_id : null;
      if (sid && UUID_RE.test(sid)) sessionIds.add(sid);
    }
  }

  return {
    sessionIds: Array.from(sessionIds),
    memberIds: Array.from(memberIds),
    inReplyTo,
  };
}
