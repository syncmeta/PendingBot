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

### Resolved: group billing skipped users are excluded from future splits

Initial review of `supabase/migrations/0045_group_chat_rpcs.sql` made this look unfixed, but later migration `supabase/migrations/0066_group_member_freeze_and_default_handle.sql` replaces `pendingbot.apply_audit_split` and handles both `skipped_overdrawn` and `skipped_capped`.

Live verification on 2026-05-25 confirmed the linked database function body contains the skipped-state branch and sets `group_member_billing.overdrawn = true`.

Residual action: keep a regression test so future migrations do not accidentally restore the older 0045 behavior.

### P1: Attachment DB read policy is broader than the Worker download policy

`apps/edge/src/routes/upload.ts` only serves raw bytes to the uploader or a current participant of a non-deleted message that references the attachment. `supabase/migrations/0063_attachments_rls_avatar_visibility.sql` allows direct DB reads for any current participant of `attachments.conversation_id`, regardless of message reference or deleted status.

Risk: raw bytes stay Worker-gated, but direct PostgREST reads can expose filenames, mime type, size, summary/tags, and `r2_key` for conversation-bound attachments after a message is deleted or never referenced.

Recommended fix: keep chat attachments uploader-only at the DB layer or base participant access on non-deleted message references. Split avatar visibility into a separate policy path that does not widen all attachments.

### P1: Crew and temporary-group billing responsibility was not wired into the audit layer

The audit debit branch in `apps/edge/src/llm/router.ts` handles normal groups and single `userId` billing. It does not resolve `temporary_group` / `crew` conversations to `responsible_subject_id` and `billing_debit_subject`.

Risk: Crew or bot-created temporary-group model calls can become free if only `conversationId` is supplied, or can charge the wrong user if callers pass `userId` as a local workaround.

Fixed on 2026-05-25 in `apps/edge/src/llm/router.ts`: audit persistence now resolves a single billable target from conversation type: group split, responsible subject, or legacy user. Crew and temporary-group turns debit `billing_debit_subject`, and the audit row metadata records the chosen subject target.

## Medium Priority Findings

### JWT verification should bind issuer, audience, and role

`packages/identity/src/jwt.ts` verifies the Supabase JWKS signature and allowed algorithms, but does not pass `issuer` or `audience` to `jwtVerify`. The payload schema accepts optional `role`.

Risk: the current signature check is strong, but the token semantics are looser than the app expects.

Recommended fix: enforce expected issuer, audience, and `role === 'authenticated'` in the auth middleware.

### Definer helper RPCs should not let callers probe another user id

Several RLS helper functions accept a `p_user_id` parameter and are executable by `authenticated` because policies call them. That is fine when policies pass `auth.uid()`, but direct RPC callers could pass another user's id and probe subject, Crew, temporary-group, or runner visibility.

Fixed on 2026-05-25 in `supabase/migrations/20260524180643_bind_definer_helpers_to_auth_uid.sql`: the helper functions now return false unless `auth.uid()` is null (service role) or `p_user_id = auth.uid()`.

### Legacy helper functions have mutable search_path

Supabase advisors flagged several legacy helper/trigger functions with role-mutable `search_path`, including `uuidv7`, preset handle helpers, and group-billing freeze triggers.

Fixed on 2026-05-25 in `supabase/migrations/20260524181807_pin_legacy_function_search_path.sql`: these functions now pin `search_path` explicitly.

### Admin support powers are well-gated but highly sensitive

The board consistently gates admin pages and server actions through `requireAdmin()`, and sensitive support actions are audited. `generateLoginCode()` correctly avoids logging the OTP itself.

Residual risk: login-code generation is effectively account takeover by support. Keep it admin-only, short-lived, audited, and consider a break-glass reason field before wider operational use.

### Test-account request logging needs retention and redaction policy

The test-account logger is opt-in by user flag and service-role only, but it stores request metadata including IP, route, query, client version, and platform.

Risk: this is reasonable for diagnostics, but it needs a retention/redaction policy before it becomes a silent privacy dataset.

### Realtime metering logs must stay allowlist-only

`apps/edge/src/durable-objects/realtime-meter.ts` previously logged full upstream `session.created` / `session.updated` event payloads for diagnostics. Those events can include generated realtime instructions assembled from bot memory, notes, skills, and conversation context.

Fixed on 2026-05-25: the meter now logs only event type, session id, model, and error code/type, and `apps/edge/tests/privacy-logging.test.ts` locks out future `JSON.stringify(msg)` logging of realtime events.

### Dependency advisories were present in the lockfile

`bun audit` on 2026-05-25 reported 9 advisories, including a high-severity Next.js App Router middleware/proxy bypass advisory and moderate advisories in PostCSS, Vite, ws, esbuild, Hono, and qs.

Fixed on 2026-05-25: workspace constraints now require patched Next/PostCSS/Hono/Vite versions, root overrides force patched transitive `qs`, `ws`, and `esbuild`, and `bun audit` returns `No vulnerabilities found`.

## Positive Findings

- All current `pendingbot` tables in the linked database have RLS enabled.
- Linked `pendingbot.apply_audit_split` already persists skipped group-billing states through the later `0066` migration.
- Edge CORS defaults to deny-all when `ALLOWED_ORIGIN` is not configured.
- The board admin surface uses a route layout gate plus server-action rechecks before service-role access.
- Raw attachment bytes are private R2 objects served through Worker authorization.
- Code-exec tool requests are approval-gated before user-provided code is run.

## Dead Code and Temporary Design Notes

- Historical `discuss_settings`, `surf_runs`, and `review_runs` tables are dropped or renamed by migrations and do not appear as active app code.
- `apps/envelope-lab` was removed on 2026-05-25; envelope production logic now lives only in Edge/iOS paths.
- `supabase/migrations/0025_dolor_preset_wip_stub.sql` is historical seed migration text, not current runtime logic.
- The remaining temporary-design risk is not dead code; it is unfinished foundation around Crew/temporary-group billing, runner permissions, and subject wallets.

## Architecture Notes Added on 2026-05-25

- User-facing Edge routes use `serviceClient()` heavily after `requireSession()`, with authorization proven inline per handler. This is workable but hard to audit; the next structural step is a shared authorization layer that resolves resources under user identity before service-role writes.
- Supabase advisors now have a repo gate: `scripts/supabase-advisor-gate.ts` with `docs/supabase-advisor-allowlist.json`. The gate allows only documented service-role-only security INFO entries and fails unlisted security WARN/ERROR findings. Live remains blocked until the pending security migrations are deployed and Auth leaked-password/MFA settings are resolved.
- Voice metering is split between 1v1 Realtime and group voice DOs. Shared cost/audit/log-redaction primitives would reduce billing drift and prevent privacy fixes from landing in only one voice path.
- Group RealtimeKit voice now has an explicit media-cost trail: the RoomVoiceDO records RealtimeKit audio participant seconds at teardown, prices them via `billing_config.cloudflare_realtimekit_audio_participant_usd_per_minute`, writes a `cloudflare_realtimekit_media` audit row, and lets normal group split billing debit by each human's in-call seconds. This closes the previous "OpenAI tokens billed, SFU/media minutes invisible" gap; the remaining production check is to calibrate against Cloudflare's active-session usage once real RealtimeKit billing data is available.
