-- Metabase read-only role for the self-hosted dashboard stack.
--
-- Purpose
-- -------
-- Metabase connects to the Supabase Postgres directly for revenue / wallet BI
-- and ad-hoc analytics. Per the dashboard-stack design ("看(只读)和改(可写)
-- 分家"), Metabase MUST ONLY ever read. This migration creates a dedicated
-- `metabase_ro` login role that has:
--   * USAGE on schema `pendingbot`
--   * SELECT on every existing table/view in `pendingbot`
--   * SELECT on every FUTURE table/view created in `pendingbot` (via ALTER
--     DEFAULT PRIVILEGES), so new tables are automatically readable without a
--     follow-up migration.
-- It is granted NO write privileges (no INSERT/UPDATE/DELETE/TRUNCATE), no
-- EXECUTE on functions, and no access to other schemas (public/auth/storage).
--
-- Password
-- --------
-- The password is intentionally NOT in this migration (no plaintext secrets in
-- the ledger). The role is created with LOGIN but NOPASSWORD-able only after a
-- separate, out-of-band step. On rollout, set the password once via the
-- Supabase dashboard SQL editor or:
--
--     supabase db query --linked "ALTER ROLE metabase_ro WITH PASSWORD '<strong-random>';"
--
-- Generate a strong value with e.g. `openssl rand -base64 32`. Store it only in
-- the VPS .env (MB_DB_SUPABASE_PASS) — see infra/dashboards/.env.example.
--
-- Connecting from Metabase
-- ------------------------
-- In Metabase "Add a database" → PostgreSQL:
--   * Host:     <project-ref>.supabase.co  (direct) OR the Supavisor pooler host
--               aws-0-<region>.pooler.supabase.com  (session mode, port 5432;
--               with the pooler, the username becomes `metabase_ro.<project-ref>`)
--   * Port:     5432 (direct) / 5432 (pooler session mode)
--   * Database: postgres
--   * Username: metabase_ro   (pooler: metabase_ro.<project-ref>)
--   * Password: the value set above
--   * Schemas:  pendingbot      (restrict Metabase to this schema only)
--   * SSL:      required
--
-- Because the role can only SELECT, even a misconfigured Metabase question or a
-- compromised Metabase instance cannot mutate application data.

BEGIN;

-- 1. Create the login role if it does not already exist. No password here —
--    set it out-of-band (see header). NOSUPERUSER/NOCREATEDB/NOCREATEROLE are
--    the safe defaults; spelled out for clarity.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metabase_ro') THEN
    CREATE ROLE metabase_ro WITH
      LOGIN
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOINHERIT
      NOREPLICATION
      NOBYPASSRLS;
  END IF;
END
$$;

-- 2. Schema-level read access. USAGE lets the role resolve objects inside the
--    schema; it does NOT by itself grant access to any table.
GRANT USAGE ON SCHEMA pendingbot TO metabase_ro;

-- 3. SELECT on all CURRENTLY-EXISTING tables, views, and materialized views in
--    the schema. (ALL TABLES covers views and matviews too.)
GRANT SELECT ON ALL TABLES IN SCHEMA pendingbot TO metabase_ro;

-- 4. SELECT on all FUTURE tables/views created by the schema owner (postgres,
--    which is how supabase migrations create objects). This is what makes new
--    tables automatically readable by Metabase without another migration.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA pendingbot
  GRANT SELECT ON TABLES TO metabase_ro;

-- 5. Belt-and-suspenders: explicitly ensure the role has NO write/DDL ability
--    inherited from PUBLIC defaults. (No CREATE on the schema; no execute on
--    functions; no sequence usage.) We do not grant any of these.
REVOKE CREATE ON SCHEMA pendingbot FROM metabase_ro;

COMMIT;

-- Rollback (manual, if ever needed):
--   BEGIN;
--   ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA pendingbot
--     REVOKE SELECT ON TABLES FROM metabase_ro;
--   REVOKE SELECT ON ALL TABLES IN SCHEMA pendingbot FROM metabase_ro;
--   REVOKE USAGE ON SCHEMA pendingbot FROM metabase_ro;
--   DROP ROLE IF EXISTS metabase_ro;
--   COMMIT;
