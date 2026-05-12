import type { Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import type { AppBindings } from '../types';

// Typed error envelope used by every /v1 route. Replaces the old
// free-shape `c.json({ error: '...', detail?, message? }, status)` that
// the May-2026 audit flagged as 100+ inconsistent forms — sometimes
// `error` was a machine code (`invalid_body`), sometimes a human
// sentence (`'号码无效或已撤销'`), sometimes both via a `message` field.
//
// Shape:
//   { error: { code: ApiErrorCode, message?: string, detail?: unknown } }
//
//   • `code`    — stable snake_case identifier. The vocabulary is the
//                  union below. Adding a code = adding to the union.
//                  iOS branches on this; future LLM-based error analysis
//                  reads this. No i18n on the code itself.
//   • `message` — optional human-readable string (Chinese per product
//                  default). Currently shown verbatim by iOS; future
//                  iOS UI may swap to its own localized strings keyed
//                  by `code` and treat `message` as fallback.
//   • `detail`  — optional structured payload (e.g. { quota_bytes,
//                  used_bytes } for quota_exceeded). Free shape; meant
//                  for debugging / structured rendering.

export type ApiErrorCode =
  // ── Generic ───────────────────────────────────────────────
  | 'invalid_body'
  | 'invalid_id'
  | 'invalid_query'
  | 'not_found'
  | 'forbidden'
  | 'unauthorized'
  | 'conflict'
  | 'rate_limited'
  | 'database_error'
  | 'internal_error'
  | 'upstream_error'
  | 'upstream_unavailable'

  // ── Auth / session ────────────────────────────────────────
  | 'session_not_found'
  | 'session_forbidden'
  | 'session_ended'
  | 'session_expired'
  | 'session_conversation_mismatch'

  // ── Billing ───────────────────────────────────────────────
  | 'insufficient_balance'
  | 'quota_exceeded'
  | 'redemption_not_found'
  | 'redemption_already_used'

  // ── Voice ─────────────────────────────────────────────────
  | 'voice_region_unsupported'
  | 'voice_bot_disabled'
  | 'voice_upstream_failed'

  // ── Attachments ───────────────────────────────────────────
  | 'attachment_not_found'
  | 'attachment_not_owned'
  | 'attachment_conversation_mismatch'
  | 'attachment_object_missing'
  | 'attachment_too_large'
  | 'attachment_unsupported_mime'
  | 'attachment_missing_field'

  // ── Conversations / messages ──────────────────────────────
  | 'conversation_not_found'
  | 'conversation_no_access'
  | 'conversation_has_no_bot'
  | 'self_chat_not_allowed'

  // ── Friend / contact / handles ────────────────────────────
  | 'handle_required'
  | 'handle_not_found'
  | 'peer_not_found'
  | 'already_contacts'
  | 'cannot_add_self'
  | 'request_not_found'
  | 'request_not_yours'

  // ── Groups ────────────────────────────────────────────────
  | 'not_a_participant'
  | 'group_request_not_found'
  | 'group_handle_invalid';

export interface ApiErrorBody {
  error: {
    code: ApiErrorCode;
    message?: string;
    detail?: unknown;
  };
}

/**
 * Standard error responder. Use this for every error path in routes;
 * see ApiErrorCode for the vocabulary.
 */
export function jsonError(
  c: Context<AppBindings>,
  status: ContentfulStatusCode,
  code: ApiErrorCode,
  opts?: { message?: string; detail?: unknown },
): Response {
  const body: ApiErrorBody = {
    error: {
      code,
      ...(opts?.message != null ? { message: opts.message } : {}),
      ...(opts?.detail !== undefined ? { detail: opts.detail } : {}),
    },
  };
  return c.json(body, status);
}
