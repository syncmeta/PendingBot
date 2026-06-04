-- Rename the BI read-only role: metabase_ro -> bi_ro.
--
-- "metabase_ro" was named when the BI tool was going to be Metabase. The stack
-- now uses Grafana Cloud, so `bi_ro` reads truer. This is a PURE rename:
-- ALTER ROLE ... RENAME preserves every GRANT, the ALTER DEFAULT PRIVILEGES
-- entries (they key on role OID, which RENAME keeps), and the password
-- (scram-sha-256, which Supabase PG15 uses, survives a role rename — only
-- legacy md5 would be cleared). No grant re-application needed; the earlier
-- migrations that GRANTed to metabase_ro continue to apply to the same role.
--
-- Client impact: the Grafana datasource username (pooler form
-- `metabase_ro.<project-ref>`) must be updated to `bi_ro.<project-ref>`.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metabase_ro')
     AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_ro') THEN
    ALTER ROLE metabase_ro RENAME TO bi_ro;
  END IF;
END $$;
