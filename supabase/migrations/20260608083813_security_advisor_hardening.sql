-- Security advisor remediation — the real holes only.
-- (Intentional findings left as-is and explained in docs/tech-debt.md:
--  the 6 bi_* SECURITY DEFINER views — deliberate for Grafana BI / bi_ro;
--  the 16 rls_enabled_no_policy tables — service-role-only, locked = secure;
--  the 72 authenticated SECURITY DEFINER functions — the curated RPC surface
--  the harden migration 20260524175632 explicitly granted; pg_net in public —
--  risky to relocate. leaked-password-protection is a dashboard Auth toggle.)

BEGIN;

-- ── 1. pnc_ledger: the one real data hole (rls_disabled_in_public, ERROR) ──
-- The billing ledger had RLS OFF with anon=SELECT and authenticated=
-- INSERT/SELECT/UPDATE/DELETE — any signed-in user could read/tamper the
-- WHOLE ledger and anon could read it. me.ts /wallet/v2 reads it with the
-- USER's client and already documents the intended model ("RLS 仅本人"), which
-- never existed because RLS was off. No SECURITY INVOKER function writes the
-- ledger (verified), and all edge writes use the service-role client, so:
--   * anon  → no access at all
--   * authenticated → read-only, own subjects only (RLS), never write
--   * service_role + SECURITY DEFINER billing fns → unaffected (bypass RLS)
REVOKE ALL              ON pendingbot.pnc_ledger FROM anon;
REVOKE INSERT, UPDATE, DELETE ON pendingbot.pnc_ledger FROM authenticated;
ALTER TABLE pendingbot.pnc_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pnc_ledger_subject_read ON pendingbot.pnc_ledger;
CREATE POLICY pnc_ledger_subject_read
  ON pendingbot.pnc_ledger FOR SELECT TO authenticated
  USING (pendingbot.subject_has_user_access(subject_id, auth.uid()));

-- ── 2. assign_message_seq: trigger helper exposed via /rest/v1/rpc ──
-- (anon_security_definer_function_executable, WARN). It slipped the
-- 20260524175632 schema-wide REVOKE (PUBLIC default execute). Triggers run it
-- regardless of EXECUTE grant, so revoking from PUBLIC breaks nothing.
REVOKE EXECUTE ON FUNCTION pendingbot.assign_message_seq() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pendingbot.assign_message_seq() FROM anon, authenticated;

-- ── 3. function_search_path_mutable (14 WARN): pin search_path ──
-- Prevents search-path injection (esp. on the SECURITY DEFINER billing fns).
-- All resolve names within pendingbot/public; pg_catalog stays implicit-first.
ALTER FUNCTION pendingbot._crew_bot_display_name(p_bot_id uuid) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot._crew_caller_can_act_for_subject(p_subject_id uuid, p_caller uuid) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot._crew_caller_owns_bot(p_bot_id uuid, p_caller uuid) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot._grp_caller_role(p_subject_id uuid, p_caller uuid) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot._grp_require_caller() SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot._grp_require_group_subject(p_subject_id uuid) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.apply_group_contribution(p_subject_id uuid, p_amount_micros bigint) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.apply_group_pool_spend(p_subject_id uuid, p_spend_micros bigint) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.apply_group_refund(p_subject_id uuid, p_refund_micros bigint) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.apply_partial_withdraw(p_subject_id uuid, p_user_id uuid, p_amount_micros bigint) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.bot_friend_inquiries_touch_updated() SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.crew_propose_split_distinct(p_shares jsonb, p_seed bigint) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.normalize_email(p_email text) SET search_path = pendingbot, public;
ALTER FUNCTION pendingbot.tg_subjects_sync_kind() SET search_path = pendingbot, public;

COMMIT;
