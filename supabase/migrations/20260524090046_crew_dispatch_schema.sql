-- Crew dispatch schema foundation:
-- - coding-agent session state;
-- - structured events instead of raw terminal spam in messages;
-- - dependencies, mailbox, file claims, and permission requests.

BEGIN;

SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.crew_sessions (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  initiating_member_id uuid NOT NULL REFERENCES pendingbot.temporary_group_members(id),
  assigned_to_member_id uuid REFERENCES pendingbot.temporary_group_members(id),
  runner_host_id uuid,
  runner_kind text NOT NULL CHECK (runner_kind IN (
    'cloud_sandbox',
    'local_claude_code',
    'local_codex',
    'local_opencode',
    'local_kilo'
  )),
  status text NOT NULL DEFAULT 'queued' CHECK (status IN (
    'queued',
    'waiting_runner',
    'running',
    'waiting_permission',
    'blocked',
    'completed',
    'failed',
    'cancelled'
  )),
  task_brief text NOT NULL,
  progress_summary text,
  last_context_cursor text,
  final_result_message_id uuid REFERENCES pendingbot.messages(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz
);

CREATE INDEX IF NOT EXISTS crew_sessions_crew_status_idx
  ON pendingbot.crew_sessions(crew_conversation_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS crew_sessions_subject_idx
  ON pendingbot.crew_sessions(responsible_subject_id, created_at DESC);

CREATE TABLE IF NOT EXISTS pendingbot.session_events (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_session_id uuid NOT NULL REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN (
    'queued',
    'runner_selected',
    'started',
    'context_injected',
    'status',
    'tool_call',
    'tool_result',
    'permission_requested',
    'permission_resolved',
    'artifact_created',
    'posted_to_crew',
    'blocked',
    'completed',
    'failed',
    'cancelled'
  )),
  visibility text NOT NULL DEFAULT 'controllers' CHECK (visibility IN (
    'controllers',
    'crew_members',
    'private_system'
  )),
  summary text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS session_events_session_time_idx
  ON pendingbot.session_events(crew_session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS session_events_type_time_idx
  ON pendingbot.session_events(event_type, created_at DESC);

CREATE TABLE IF NOT EXISTS pendingbot.session_dependencies (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_session_id uuid NOT NULL REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  depends_on_session_id uuid REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  dependency_type text NOT NULL CHECK (dependency_type IN (
    'wait_for_result',
    'wait_for_permission',
    'wait_for_artifact',
    'wait_for_file_claim',
    'manual_blocker'
  )),
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN (
    'waiting',
    'ready',
    'resolved',
    'cancelled'
  )),
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE INDEX IF NOT EXISTS session_dependencies_session_idx
  ON pendingbot.session_dependencies(crew_session_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS session_dependencies_depends_on_idx
  ON pendingbot.session_dependencies(depends_on_session_id, status)
  WHERE depends_on_session_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS pendingbot.session_mailbox_items (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  sender_session_id uuid REFERENCES pendingbot.crew_sessions(id) ON DELETE SET NULL,
  recipient_session_id uuid REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  message_kind text NOT NULL DEFAULT 'status' CHECK (message_kind IN (
    'status',
    'question',
    'handoff',
    'result',
    'blocker'
  )),
  summary text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'unread' CHECK (status IN ('unread', 'read', 'archived')),
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz
);

CREATE INDEX IF NOT EXISTS session_mailbox_recipient_idx
  ON pendingbot.session_mailbox_items(recipient_session_id, status, created_at DESC)
  WHERE recipient_session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_mailbox_crew_idx
  ON pendingbot.session_mailbox_items(crew_conversation_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS pendingbot.session_file_claims (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_session_id uuid NOT NULL REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  workspace_root text NOT NULL,
  path_pattern text NOT NULL,
  claim_type text NOT NULL CHECK (claim_type IN ('read', 'write', 'exclusive_write')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz
);

CREATE INDEX IF NOT EXISTS session_file_claims_session_idx
  ON pendingbot.session_file_claims(crew_session_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS session_file_claims_path_idx
  ON pendingbot.session_file_claims(workspace_root, path_pattern, status);

CREATE TABLE IF NOT EXISTS pendingbot.permission_requests (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_session_id uuid NOT NULL REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  requested_action text NOT NULL,
  risk_level text NOT NULL CHECK (risk_level IN ('low', 'medium', 'high')),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending',
    'approved',
    'denied',
    'expired',
    'cancelled'
  )),
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decided_at timestamptz
);

CREATE INDEX IF NOT EXISTS permission_requests_session_idx
  ON pendingbot.permission_requests(crew_session_id, status, requested_at DESC);
CREATE INDEX IF NOT EXISTS permission_requests_subject_idx
  ON pendingbot.permission_requests(responsible_subject_id, status, requested_at DESC);

CREATE OR REPLACE FUNCTION pendingbot.can_view_crew_session(
  p_crew_session_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.crew_sessions cs
     WHERE cs.id = p_crew_session_id
       AND pendingbot.can_view_temporary_group(cs.crew_conversation_id, p_user_id)
  )
$$;

ALTER FUNCTION pendingbot.can_view_crew_session(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.can_view_crew_session(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_crew_session(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_crew_session(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.can_control_crew_session(
  p_crew_session_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.crew_sessions cs
     WHERE cs.id = p_crew_session_id
       AND pendingbot.subject_has_user_access(cs.responsible_subject_id, p_user_id)
  )
$$;

ALTER FUNCTION pendingbot.can_control_crew_session(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.can_control_crew_session(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.can_control_crew_session(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.can_control_crew_session(uuid, uuid) TO service_role;

ALTER TABLE pendingbot.crew_sessions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crew_sessions_view ON pendingbot.crew_sessions;
CREATE POLICY crew_sessions_view
  ON pendingbot.crew_sessions FOR SELECT TO authenticated
  USING (pendingbot.can_view_crew_session(id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.crew_sessions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.crew_sessions TO service_role;

ALTER TABLE pendingbot.session_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_events_view ON pendingbot.session_events;
CREATE POLICY session_events_view
  ON pendingbot.session_events FOR SELECT TO authenticated
  USING (
    visibility <> 'private_system'
    AND pendingbot.can_view_crew_session(crew_session_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.session_events TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.session_events TO service_role;

ALTER TABLE pendingbot.session_dependencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_dependencies_view ON pendingbot.session_dependencies;
CREATE POLICY session_dependencies_view
  ON pendingbot.session_dependencies FOR SELECT TO authenticated
  USING (pendingbot.can_view_crew_session(crew_session_id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.session_dependencies TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.session_dependencies TO service_role;

ALTER TABLE pendingbot.session_mailbox_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_mailbox_items_view ON pendingbot.session_mailbox_items;
CREATE POLICY session_mailbox_items_view
  ON pendingbot.session_mailbox_items FOR SELECT TO authenticated
  USING (
    pendingbot.can_view_temporary_group(crew_conversation_id, auth.uid())
    OR pendingbot.subject_has_user_access(responsible_subject_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.session_mailbox_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.session_mailbox_items TO service_role;

ALTER TABLE pendingbot.session_file_claims ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_file_claims_view ON pendingbot.session_file_claims;
CREATE POLICY session_file_claims_view
  ON pendingbot.session_file_claims FOR SELECT TO authenticated
  USING (pendingbot.can_view_crew_session(crew_session_id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.session_file_claims TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.session_file_claims TO service_role;

ALTER TABLE pendingbot.permission_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS permission_requests_view ON pendingbot.permission_requests;
CREATE POLICY permission_requests_view
  ON pendingbot.permission_requests FOR SELECT TO authenticated
  USING (
    pendingbot.can_view_crew_session(crew_session_id, auth.uid())
    OR pendingbot.subject_has_user_access(responsible_subject_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.permission_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.permission_requests TO service_role;

COMMIT;
