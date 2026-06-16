import type { Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import type { AppBindings } from '../types';

// Typed error envelope used by every /v1 route.
//
// Shape:
//   { error: { code: ApiErrorCode, message?: string, detail?: unknown } }
//
//   • `code`    — stable snake_case identifier from the ApiErrorCode
//                  union below. Adding a code = adding to the union.
//                  iOS branches on this. No i18n on the code itself.
//   • `message` — optional human-readable string, Chinese per product
//                  default. iOS surfaces verbatim when present.
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
  | 'upgrade_required'

  // ── Auth / session ────────────────────────────────────────
  | 'session_not_found'
  | 'session_forbidden'
  | 'session_ended'
  | 'session_expired'
  | 'session_conversation_mismatch'

  // ── Billing ───────────────────────────────────────────────
  | 'insufficient_balance'
  | 'quota_exceeded'
  | 'billing_disabled'
  | 'subject_not_found'
  | 'subject_mismatch'
  | 'subject_forbidden'
  | 'redemption_not_found'
  | 'redemption_already_used'

  // ── Billing webhooks (Polar + RevenueCat — routes/billing-webhooks.ts) ─
  | 'webhook_not_configured'   // secret env var missing — return 501
  | 'invalid_signature'        // HMAC / JWS verification failed
  | 'invalid_json'             // webhook body wasn't parseable JSON
  | 'invalid_auth'             // RevenueCat webhook Authorization 头不匹配
  | 'polar_not_configured'     // POLAR_ACCESS_TOKEN / POLAR_PNC_METER_ID 缺失 — 501

  // ── Voice ─────────────────────────────────────────────────
  | 'voice_region_unsupported'
  | 'voice_bot_disabled'
  | 'voice_upstream_failed'
  | 'not_in_room'

  // ── Attachments ───────────────────────────────────────────
  | 'attachment_not_found'
  | 'attachment_not_owned'
  | 'attachment_object_missing'
  | 'attachment_too_large'
  | 'attachment_missing_field'

  // ── Conversations / messages ──────────────────────────────
  | 'conversation_not_found'
  | 'conversation_no_access'
  | 'conversation_has_no_bot'
  | 'no_model_pool'
  | 'self_chat_not_allowed'

  // ── Friend / contact / handles ────────────────────────────
  | 'handle_required'
  | 'handle_not_found'
  | 'peer_not_found'
  | 'source_group_forbidden'
  | 'peer_not_in_source_group'
  | 'peer_account_deleted'
  | 'already_contacts'
  | 'cannot_add_self'
  | 'request_not_found'
  | 'request_not_yours'

  // ── Groups ────────────────────────────────────────────────
  | 'not_a_participant'
  | 'group_request_not_found'
  | 'group_handle_invalid'

  // ── Crew (Phase 2) ────────────────────────────────────────
  // Surfaced by /v1/crews/* and /v1/share-changes/*. The DB-side
  // story:
  //   * `crew_cycle`              — crew_attach_as_child would
  //                                  introduce a cycle (cycle-guard
  //                                  trigger fired).
  //   * `crew_attach_forbidden`   — caller cannot act for the
  //                                  child crew's responsible
  //                                  subject (RPC 42501).
  //   * `crew_share_invalid`      — share_bps outside 1..9999 or
  //                                  malformed proposed_shares
  //                                  payload.
  //   * `crew_not_found`          — crew row missing or not visible
  //                                  to caller (membership check
  //                                  failed).
  //   * `crew_share_change_forbidden` — caller cannot decide on a
  //                                  share-change proposal as the
  //                                  asserted subject.
  | 'crew_cycle'
  | 'crew_attach_forbidden'
  | 'crew_share_invalid'
  | 'crew_not_found'
  | 'crew_share_change_forbidden'

  // ── Permission request (spec v2 §10 — Permission Request mode) ────
  // Surfaced by /v1/permission-requests/:id/decide and the crew/session
  // permission-mode PATCH endpoints.
  //   * `permission_request_not_found`        — id doesn't resolve to a row,
  //                                              or RLS hid it from the
  //                                              caller (same shape; we
  //                                              don't leak existence).
  //   * `permission_request_forbidden`        — caller isn't authorised to
  //                                              decide (user_account
  //                                              non-owner / group_account
  //                                              non-owner/admin).
  //   * `permission_request_already_decided`  — row.status != 'pending';
  //                                              idempotent re-decide is a
  //                                              client mistake we surface
  //                                              loudly so the UI clears
  //                                              the pending state.
  | 'permission_request_not_found'
  | 'permission_request_forbidden'
  | 'permission_request_already_decided';

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
