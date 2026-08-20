-- BI aggregate views for the Grafana dashboard stack.
--
-- Problem (docs/tech-debt.md §metabase_ro): the BI read-only role is
-- NOBYPASSRLS. The group-billing tables (group_pools / group_contributions /
-- group_pledges) and bots / group_join_requests carry RLS policies that either
-- match 0 rows without an auth.uid() (TO authenticated) or call helper
-- functions the role can't EXECUTE (→ 42501). So Grafana dashboards 03 (group
-- pool) and 05 (conversion funnel) come back empty or error out.
--
-- Fix: expose ONLY the aggregates the dashboards need, through views owned by
-- postgres (the schema/table owner). A view executes with its owner's
-- privileges, and RLS is not enforced for the table owner — so the view reads
-- the base rows, aggregates them, and the BI role only ever sees the aggregate
-- (or, for the funnel, a minimal id+timestamp projection it must DISTINCT-count
-- itself). We deliberately do NOT add a loose `USING (true)` SELECT policy on
-- the RLS tables: a read-only analytics role must never be able to scan raw
-- user rows. (No `security_invoker` clause → default definer semantics, which
-- also keeps this valid on PG14.)
--
-- Auto-grant: the metabase_ro migration set ALTER DEFAULT PRIVILEGES FOR ROLE
-- postgres ... GRANT SELECT ON TABLES, so these postgres-owned views are
-- granted to the BI role automatically on creation. The guarded GRANT below is
-- belt-and-suspenders for the case the role already exists.

BEGIN;

-- 03 · group pool / pledge KPI gauges. One row; each gauge panel SELECTs its
-- own column. Pure SUM/COUNT — no row ever leaves the view.
CREATE OR REPLACE VIEW pendingbot.bi_group_pool_summary AS
SELECT
  (SELECT COALESCE(SUM(total_remaining_pnc_micros), 0)
     FROM pendingbot.group_pools)                                 AS pool_remaining_micros,
  (SELECT COALESCE(SUM(contributed_pnc_micros), 0)
     FROM pendingbot.group_contributions WHERE status = 'active') AS active_contributed_micros,
  (SELECT COUNT(DISTINCT subject_id)
     FROM pendingbot.group_contributions WHERE status = 'active') AS active_contributor_groups,
  (SELECT COALESCE(SUM(pledge_pnc_micros), 0)
     FROM pendingbot.group_pledges WHERE status = 'active')       AS active_pledged_micros,
  (SELECT COUNT(DISTINCT subject_id)
     FROM pendingbot.group_pledges WHERE status = 'active')       AS active_pledge_groups;

-- 03 · per-group pool usage table. One aggregated row per group subject —
-- group_name + rolled-up pool/contribution/pledge totals, never member rows.
CREATE OR REPLACE VIEW pendingbot.bi_group_pool_detail AS
SELECT
  gp.subject_id,
  s.display_name                       AS group_name,
  gp.total_remaining_pnc_micros        AS pool_remaining_micros,
  gp.share_index,
  COALESCE(con.active_contributors, 0) AS active_contributors,
  COALESCE(con.contributed_micros, 0)  AS contributed_micros,
  COALESCE(pl.active_pledgers, 0)      AS active_pledgers,
  COALESCE(pl.pledged_micros, 0)       AS pledged_micros,
  gp.updated_at
FROM pendingbot.group_pools gp
LEFT JOIN pendingbot.subjects s ON s.id = gp.subject_id
LEFT JOIN (
  SELECT subject_id,
         COUNT(DISTINCT contributor_user_id) AS active_contributors,
         SUM(contributed_pnc_micros)         AS contributed_micros
  FROM pendingbot.group_contributions
  WHERE status = 'active'
  GROUP BY subject_id
) con ON con.subject_id = gp.subject_id
LEFT JOIN (
  SELECT subject_id,
         COUNT(DISTINCT user_id) AS active_pledgers,
         SUM(pledge_pnc_micros)  AS pledged_micros
  FROM pendingbot.group_pledges
  WHERE status = 'active'
  GROUP BY subject_id
) pl ON pl.subject_id = gp.subject_id;

-- 05 · funnel stage "created a bot". Minimal (creator_id, created_at) rows so
-- Grafana can COUNT(DISTINCT creator_id) under its own $__timeFilter. Only the
-- creator id + timestamp — the analytics primitives the funnel needs, nothing
-- else from the bots row.
CREATE OR REPLACE VIEW pendingbot.bi_bot_creations AS
SELECT creator_id, created_at
FROM pendingbot.bots
WHERE creator_id IS NOT NULL;

-- 05 · funnel stage "joined a group" (approved only). Minimal id + timestamps.
CREATE OR REPLACE VIEW pendingbot.bi_group_joins_approved AS
SELECT requester_id, decided_at, created_at
FROM pendingbot.group_join_requests
WHERE status = 'approved';

-- Belt-and-suspenders explicit grant (the default-privileges rule already
-- covers postgres-owned views; this is a no-op when that fired, and a safety
-- net if the role pre-exists in some other shape).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metabase_ro') THEN
    GRANT SELECT ON
      pendingbot.bi_group_pool_summary,
      pendingbot.bi_group_pool_detail,
      pendingbot.bi_bot_creations,
      pendingbot.bi_group_joins_approved
    TO metabase_ro;
  END IF;
END
$$;

COMMIT;
