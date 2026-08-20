-- Runner host / lease schema foundation:
-- - a subject-scoped registry for cloud and macOS runner hosts;
-- - short-lived per-session leases;
-- - FK from crew_sessions.runner_host_id to runner_hosts.

BEGIN;

SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.runner_hosts (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  device_id uuid REFERENCES pendingbot.device_tokens(id) ON DELETE SET NULL,
  platform text NOT NULL CHECK (platform IN ('macos', 'cloud')),
  display_name text NOT NULL,
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  allowed_runner_kinds jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'offline' CHECK (status IN ('online', 'offline', 'disabled')),
  last_seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS runner_hosts_subject_status_idx
  ON pendingbot.runner_hosts(responsible_subject_id, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS runner_hosts_device_idx
  ON pendingbot.runner_hosts(device_id)
  WHERE device_id IS NOT NULL;

ALTER TABLE pendingbot.crew_sessions
  DROP CONSTRAINT IF EXISTS crew_sessions_runner_host_fkey;
ALTER TABLE pendingbot.crew_sessions
  ADD CONSTRAINT crew_sessions_runner_host_fkey
  FOREIGN KEY (runner_host_id)
  REFERENCES pendingbot.runner_hosts(id)
  ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS pendingbot.runner_leases (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_session_id uuid NOT NULL REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  runner_host_id uuid NOT NULL REFERENCES pendingbot.runner_hosts(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  lease_status text NOT NULL DEFAULT 'active' CHECK (lease_status IN (
    'active',
    'released',
    'expired',
    'revoked'
  )),
  granted_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  lease_token_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz
);

CREATE INDEX IF NOT EXISTS runner_leases_session_idx
  ON pendingbot.runner_leases(crew_session_id, lease_status, created_at DESC);
CREATE INDEX IF NOT EXISTS runner_leases_host_idx
  ON pendingbot.runner_leases(runner_host_id, lease_status, expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS runner_leases_active_session_uniq
  ON pendingbot.runner_leases(crew_session_id)
  WHERE lease_status = 'active';

CREATE OR REPLACE FUNCTION pendingbot.can_view_runner_host(
  p_runner_host_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.runner_hosts rh
     WHERE rh.id = p_runner_host_id
       AND pendingbot.subject_has_user_access(rh.responsible_subject_id, p_user_id)
  )
$$;

ALTER FUNCTION pendingbot.can_view_runner_host(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.can_view_runner_host(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_runner_host(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_runner_host(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.can_view_runner_lease(
  p_runner_lease_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.runner_leases rl
     WHERE rl.id = p_runner_lease_id
       AND (
         pendingbot.subject_has_user_access(rl.responsible_subject_id, p_user_id)
         OR pendingbot.can_view_crew_session(rl.crew_session_id, p_user_id)
       )
  )
$$;

ALTER FUNCTION pendingbot.can_view_runner_lease(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.can_view_runner_lease(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_runner_lease(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_runner_lease(uuid, uuid) TO service_role;

ALTER TABLE pendingbot.runner_hosts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS runner_hosts_view ON pendingbot.runner_hosts;
CREATE POLICY runner_hosts_view
  ON pendingbot.runner_hosts FOR SELECT TO authenticated
  USING (pendingbot.subject_has_user_access(responsible_subject_id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.runner_hosts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.runner_hosts TO service_role;

ALTER TABLE pendingbot.runner_leases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS runner_leases_view ON pendingbot.runner_leases;
CREATE POLICY runner_leases_view
  ON pendingbot.runner_leases FOR SELECT TO authenticated
  USING (pendingbot.can_view_runner_lease(id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.runner_leases TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.runner_leases TO service_role;

COMMIT;
