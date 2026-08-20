-- BI views, part 2: close the remaining metabase_ro RLS read gaps.
--
-- Companion to 20260604044057_bi_aggregate_views.sql. That migration covered
-- dashboards 03 (group pool) and 05 (funnel). This one covers the two
-- dashboards whose panels still read RLS-protected tables DIRECTLY:
--
--   * 04-cost-by-category — reads pendingbot.audit_log (RLS on, authenticated-
--     only SELECT policy → metabase_ro reads 0 rows, silently).
--   * 02-wallet-quota     — JOINs pendingbot.subjects for the display
--     name / subject_type / kind labels (same RLS shape → the JOIN drops every
--     row even though pnc_ledger itself is RLS-off and readable).
--
-- Same fix as before: expose ONLY what the panels need through views owned by
-- postgres (the schema owner). A view runs with its owner's privileges and RLS
-- is not enforced for the table owner, so the view reads the base rows and the
-- NOBYPASSRLS BI role only ever sees the projection. We deliberately do NOT add
-- a loose `USING (true)` SELECT policy on the RLS tables — a read-only analytics
-- role must never be able to scan raw user rows. (No `security_invoker` clause →
-- default definer semantics, also valid on PG14.)
--
-- Auto-grant: the metabase_ro migration set ALTER DEFAULT PRIVILEGES FOR ROLE
-- postgres ... GRANT SELECT ON TABLES, so these postgres-owned views are granted
-- to the BI role automatically on creation. The guarded GRANT at the bottom is
-- belt-and-suspenders for the case the role already exists in some other shape.

BEGIN;

-- 04 · per-call consumption rows for the cost-by-category panels. The panels
-- (cost by task_type, cost by model_id, daily cost timeseries) each apply their
-- own $__timeFilter(created_at) / $__timeGroup(created_at, …) + GROUP BY, so the
-- view stays ROW-LEVEL (not pre-aggregated): it exposes only the category +
-- cost + token columns those panels read, never user_id / conversation_id /
-- metadata / route_trace. Grafana does the SUM/COUNT itself, exactly like
-- bi_bot_creations feeds the funnel.
CREATE OR REPLACE VIEW pendingbot.bi_cost_by_category AS
SELECT
  created_at,
  task_type,
  model_id,
  cost_credits,
  cost_usd,
  tool_cost_usd,
  total_tokens,
  input_tokens,
  output_tokens
FROM pendingbot.audit_log;

-- 02 + 05 · subject label / owner projection. pnc_ledger is RLS-off and
-- readable directly, but several panels JOIN subjects to resolve either the
-- human-readable labels (02: display_name / subject_type / kind) or the owning
-- user (05 "Paid" funnel stage: subjects.user_id, to COUNT(DISTINCT user_id)
-- who topped up). Expose exactly those columns so the panels JOIN this view
-- instead of the RLS-protected base table. No status / created_by / timestamps /
-- group_conversation_id — nothing beyond the join keys + labels the panels read.
CREATE OR REPLACE VIEW pendingbot.bi_subjects AS
SELECT
  id,
  user_id,
  display_name,
  subject_type,
  kind
FROM pendingbot.subjects;

-- Belt-and-suspenders explicit grant (the default-privileges rule already
-- covers postgres-owned views; this is a no-op when that fired, and a safety
-- net if the role pre-exists in some other shape).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metabase_ro') THEN
    GRANT SELECT ON
      pendingbot.bi_cost_by_category,
      pendingbot.bi_subjects
    TO metabase_ro;
  END IF;
END
$$;

COMMIT;
