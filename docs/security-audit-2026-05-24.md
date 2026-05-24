# Security and Architecture Audit - 2026-05-24

Branch: `codex/security-architecture-audit`

Scope: local code review plus read-only checks against the linked Supabase project `sslzhblojwkxfdyisity`.

## Highest Priority Findings

### P0: Exposed `SECURITY DEFINER` RPC permissions are too broad

Live Supabase advisors and a direct `has_function_privilege()` query both show `anon` can execute many `SECURITY DEFINER` functions in the exposed `pendingbot` schema. Confirmed examples include:

- `pendingbot.billing_admin_grant(uuid, bigint, text)`
- `pendingbot.billing_credit(uuid, bigint, text, uuid, uuid, uuid, text, jsonb)`
- `pendingbot.billing_debit(uuid, uuid, bigint)`
- `pendingbot.billing_issue_codes(integer, bigint, text)`
- `pendingbot.start_user_bot_turn(uuid, uuid, text, uuid[])`
- `pendingbot.open_self_conv()`
- `pendingbot.open_user_bot_conv(uuid)`

Risk: any one of these functions that does not fully self-authorize can bypass RLS with owner privileges. This is the main least-privilege failure in the current system.

Recommended fix:

- Add a permission-hardening migration that revokes execute from `PUBLIC`, `anon`, and `authenticated` for every internal or worker-only function.
- Re-grant only the small set of intentionally public authenticated RPCs.
- Move trigger/internal functions to a non-exposed schema where practical.
- Set immutable `search_path` on all definer functions.
- Re-run Supabase security advisors and keep the result clean.

### P0: Device grant approval can mint over-scoped tokens

`apps/edge/src/routes/device-login.ts` validates approval by `grantKind`, but it stores `requested_scopes` from the approve request body. `apps/edge/src/lib/device-grants.ts` later trusts the stored scopes directly.

Risk: a user who is allowed to approve `pendingcrew_control` may still send `runner:write` and receive a token that passes runner endpoints, unless a separate role check happens later. That violates minimum necessary privilege.

Recommended fix: derive scopes server-side from `grantKind` and subject role, or reject any scope outside a database-checked allowed set before storing the challenge approval.

### P0: Group billing skipped users are not excluded from future splits

`apps/edge/src/lib/group-billing.ts` says skipped users get marked overdrawn by the RPC. The actual `pendingbot.apply_audit_split` body in `supabase/migrations/0045_group_chat_rpcs.sql` only updates `group_member_billing` when the split status is `debited`.

Risk: users with insufficient balance or exhausted caps remain in the payer set forever, get skipped every turn, and their share is never reallocated or billed.

Recommended fix: update `group_member_billing` for `skipped_overdrawn` and `skipped_capped`, and cover this with a regression test.

### P1: Attachment DB read policy is broader than the Worker download policy

`apps/edge/src/routes/upload.ts` only serves raw bytes to the uploader or a current participant of a non-deleted message that references the attachment. `supabase/migrations/0063_attachments_rls_avatar_visibility.sql` allows direct DB reads for any current participant of `attachments.conversation_id`, regardless of message reference or deleted status.

Risk: raw bytes stay Worker-gated, but direct PostgREST reads can expose filenames, mime type, size, summary/tags, and `r2_key` for conversation-bound attachments after a message is deleted or never referenced.

Recommended fix: keep chat attachments uploader-only at the DB layer or base participant access on non-deleted message references. Split avatar visibility into a separate policy path that does not widen all attachments.

### P1: Crew and temporary-group billing responsibility is not wired into the audit layer

The audit debit branch in `apps/edge/src/llm/router.ts` handles normal groups and single `userId` billing. It does not resolve `temporary_group` / `crew` conversations to `responsible_subject_id` and `billing_debit_subject`.

Risk: Crew or bot-created temporary-group model calls can become free if only `conversationId` is supplied, or can charge the wrong user if callers pass `userId` as a local workaround.

Recommended fix: make the audit layer resolve a single billable target from conversation type: user, group split, or responsible subject. Persist the chosen target snapshot on the audit row.

## Medium Priority Findings

### JWT verification should bind issuer, audience, and role

`packages/identity/src/jwt.ts` verifies the Supabase JWKS signature and allowed algorithms, but does not pass `issuer` or `audience` to `jwtVerify`. The payload schema accepts optional `role`.

Risk: the current signature check is strong, but the token semantics are looser than the app expects.

Recommended fix: enforce expected issuer, audience, and `role === 'authenticated'` in the auth middleware.

### Admin support powers are well-gated but highly sensitive

The board consistently gates admin pages and server actions through `requireAdmin()`, and sensitive support actions are audited. `generateLoginCode()` correctly avoids logging the OTP itself.

Residual risk: login-code generation is effectively account takeover by support. Keep it admin-only, short-lived, audited, and consider a break-glass reason field before wider operational use.

### Test-account request logging needs retention and redaction policy

The test-account logger is opt-in by user flag and service-role only, but it stores request metadata including IP, route, query, client version, and platform.

Risk: this is reasonable for diagnostics, but it needs a retention/redaction policy before it becomes a silent privacy dataset.

## Positive Findings

- All current `pendingbot` tables in the linked database have RLS enabled.
- Edge CORS defaults to deny-all when `ALLOWED_ORIGIN` is not configured.
- The board admin surface uses a route layout gate plus server-action rechecks before service-role access.
- Raw attachment bytes are private R2 objects served through Worker authorization.
- Code-exec tool requests are approval-gated before user-provided code is run.

## Dead Code and Temporary Design Notes

- Historical `discuss_settings`, `surf_runs`, and `review_runs` tables are dropped or renamed by migrations and do not appear as active app code.
- `apps/envelope-lab` contains intentional stubs and fixture switches for a lab/replay surface, not production dead code.
- `supabase/migrations/0025_dolor_preset_wip_stub.sql` is historical seed migration text, not current runtime logic.
- The remaining temporary-design risk is not dead code; it is unfinished foundation around Crew/temporary-group billing, runner permissions, and subject wallets.
