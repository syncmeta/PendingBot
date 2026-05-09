-- Address Supabase database-linter ERRORs:
--   * security_definer_view on pendingbot.v_audit_daily / v_audit_monthly
--   * rls_disabled_in_public on pendingbot.disposable_email_domains
--
-- Views (defined in 0030) are owned by `postgres`, so by default they
-- resolve RLS as the owner — which the linter (correctly) flags as a
-- privilege-escalation surface. Switch them to security_invoker so they
-- run with the caller's RLS. The only consumer is the admin board
-- (apps/board/app/(admin)/audit/page.tsx) using service_role, which
-- bypasses RLS regardless, so behavior is unchanged.
--
-- The disposable-email blocklist (0050) shipped without ENABLE RLS even
-- though pendingbot is exposed via PostgREST. The trigger that reads it
-- (pendingbot.reject_disposable_email) is SECURITY DEFINER, so enabling
-- RLS with no policies is safe — same pattern as admin_audit / llm_*
-- in 0030.

ALTER VIEW pendingbot.v_audit_daily   SET (security_invoker = on);
ALTER VIEW pendingbot.v_audit_monthly SET (security_invoker = on);

ALTER TABLE pendingbot.disposable_email_domains ENABLE ROW LEVEL SECURITY;
