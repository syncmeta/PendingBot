-- Temporary group / Crew schema foundation:
-- - conversation_type values for bot-created temporary groups and human-created Crew;
-- - metadata, members, and human-help request inbox;
-- - read helpers/RLS for members and responsible-subject controllers.

BEGIN;

SET search_path TO pendingbot, public;

ALTER TABLE pendingbot.conversations
  DROP CONSTRAINT IF EXISTS conversations_conversation_type_check;
ALTER TABLE pendingbot.conversations
  ADD CONSTRAINT conversations_conversation_type_check
  CHECK (conversation_type = ANY (ARRAY[
    'user_bot'::text,
    'user_user'::text,
    'group'::text,
    'self'::text,
    'subagent'::text,
    'temporary_group'::text,
    'crew'::text
  ]));

CREATE TABLE IF NOT EXISTS pendingbot.temporary_group_meta (
  conversation_id uuid PRIMARY KEY REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  temporary_kind text NOT NULL CHECK (temporary_kind IN ('bot_temporary_group', 'crew')),
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  initiator_type text NOT NULL CHECK (initiator_type IN ('human', 'bot')),
  initiator_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  initiator_bot_id uuid REFERENCES pendingbot.bots(id) ON DELETE SET NULL,
  source_conversation_id uuid REFERENCES pendingbot.conversations(id) ON DELETE SET NULL,
  parent_temporary_group_id uuid REFERENCES pendingbot.conversations(id) ON DELETE SET NULL,
  root_temporary_group_id uuid REFERENCES pendingbot.conversations(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closing', 'closed', 'cancelled')),
  title text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  CONSTRAINT temporary_group_meta_kind_initiator_chk CHECK (
    (temporary_kind = 'crew' AND initiator_type = 'human')
    OR
    (temporary_kind = 'bot_temporary_group' AND initiator_type = 'bot')
  ),
  CONSTRAINT temporary_group_meta_initiator_ref_chk CHECK (
    (initiator_type = 'human' AND initiator_user_id IS NOT NULL AND initiator_bot_id IS NULL)
    OR
    (initiator_type = 'bot' AND initiator_bot_id IS NOT NULL AND initiator_user_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS temporary_group_meta_subject_idx
  ON pendingbot.temporary_group_meta(responsible_subject_id, created_at DESC);
CREATE INDEX IF NOT EXISTS temporary_group_meta_source_idx
  ON pendingbot.temporary_group_meta(source_conversation_id)
  WHERE source_conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS temporary_group_meta_root_idx
  ON pendingbot.temporary_group_meta(root_temporary_group_id, created_at DESC)
  WHERE root_temporary_group_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS pendingbot.temporary_group_members (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  member_kind text NOT NULL CHECK (member_kind IN (
    'human',
    'registered_bot',
    'ephemeral_bot',
    'code_session'
  )),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  bot_id uuid REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  code_session_id uuid,
  display_name text NOT NULL,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'observer')),
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  ephemeral_spec jsonb NOT NULL DEFAULT '{}'::jsonb,
  invited_by_member_id uuid REFERENCES pendingbot.temporary_group_members(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'left', 'removed', 'expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT temporary_group_members_kind_ref_chk CHECK (
    (member_kind = 'human' AND user_id IS NOT NULL AND bot_id IS NULL AND code_session_id IS NULL)
    OR
    (member_kind = 'registered_bot' AND bot_id IS NOT NULL AND user_id IS NULL AND code_session_id IS NULL)
    OR
    (member_kind = 'ephemeral_bot' AND user_id IS NULL AND bot_id IS NULL AND code_session_id IS NULL)
    OR
    (member_kind = 'code_session' AND code_session_id IS NOT NULL AND user_id IS NULL AND bot_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS temporary_group_members_conversation_idx
  ON pendingbot.temporary_group_members(conversation_id, status, created_at);
CREATE INDEX IF NOT EXISTS temporary_group_members_user_idx
  ON pendingbot.temporary_group_members(user_id, status)
  WHERE member_kind = 'human';
CREATE INDEX IF NOT EXISTS temporary_group_members_bot_idx
  ON pendingbot.temporary_group_members(bot_id, status)
  WHERE member_kind = 'registered_bot';
CREATE UNIQUE INDEX IF NOT EXISTS temporary_group_members_active_user_uniq
  ON pendingbot.temporary_group_members(conversation_id, user_id)
  WHERE member_kind = 'human' AND status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS temporary_group_members_active_bot_uniq
  ON pendingbot.temporary_group_members(conversation_id, bot_id)
  WHERE member_kind = 'registered_bot' AND status = 'active';

CREATE TABLE IF NOT EXISTS pendingbot.human_help_requests (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  temporary_group_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  requester_member_id uuid NOT NULL REFERENCES pendingbot.temporary_group_members(id) ON DELETE CASCADE,
  requested_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz
);

CREATE INDEX IF NOT EXISTS human_help_requests_requested_user_idx
  ON pendingbot.human_help_requests(requested_user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS human_help_requests_temporary_group_idx
  ON pendingbot.human_help_requests(temporary_group_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS human_help_requests_pending_user_uniq
  ON pendingbot.human_help_requests(temporary_group_id, requested_user_id)
  WHERE status = 'pending';

CREATE OR REPLACE FUNCTION pendingbot.is_temporary_group_human_member(
  p_conversation_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.temporary_group_members tgm
     WHERE tgm.conversation_id = p_conversation_id
       AND tgm.member_kind = 'human'
       AND tgm.user_id = p_user_id
       AND tgm.status = 'active'
  )
$$;

ALTER FUNCTION pendingbot.is_temporary_group_human_member(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.is_temporary_group_human_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.is_temporary_group_human_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.is_temporary_group_human_member(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.can_view_temporary_group(
  p_conversation_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.temporary_group_meta tgm
     WHERE tgm.conversation_id = p_conversation_id
       AND tgm.status IN ('active', 'closing', 'closed')
       AND (
         pendingbot.subject_has_user_access(tgm.responsible_subject_id, p_user_id)
         OR pendingbot.is_temporary_group_human_member(tgm.conversation_id, p_user_id)
       )
  )
$$;

ALTER FUNCTION pendingbot.can_view_temporary_group(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.can_view_temporary_group(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_temporary_group(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.can_view_temporary_group(uuid, uuid) TO service_role;

ALTER TABLE pendingbot.temporary_group_meta ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS temporary_group_meta_view ON pendingbot.temporary_group_meta;
CREATE POLICY temporary_group_meta_view
  ON pendingbot.temporary_group_meta FOR SELECT TO authenticated
  USING (pendingbot.can_view_temporary_group(conversation_id, auth.uid()));

GRANT SELECT ON TABLE pendingbot.temporary_group_meta TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.temporary_group_meta TO service_role;

ALTER TABLE pendingbot.temporary_group_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS temporary_group_members_view ON pendingbot.temporary_group_members;
CREATE POLICY temporary_group_members_view
  ON pendingbot.temporary_group_members FOR SELECT TO authenticated
  USING (pendingbot.can_view_temporary_group(conversation_id, auth.uid()));

GRANT SELECT ON TABLE pendingbot.temporary_group_members TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.temporary_group_members TO service_role;

ALTER TABLE pendingbot.human_help_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS human_help_requests_view ON pendingbot.human_help_requests;
CREATE POLICY human_help_requests_view
  ON pendingbot.human_help_requests FOR SELECT TO authenticated
  USING (
    requested_user_id = auth.uid()
    OR pendingbot.can_view_temporary_group(temporary_group_id, auth.uid())
    OR pendingbot.subject_has_user_access(responsible_subject_id, auth.uid())
  );

GRANT SELECT ON TABLE pendingbot.human_help_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.human_help_requests TO service_role;

DROP POLICY IF EXISTS conversations_temporary_group_view ON pendingbot.conversations;
CREATE POLICY conversations_temporary_group_view
  ON pendingbot.conversations FOR SELECT TO authenticated
  USING (
    conversation_type IN ('temporary_group', 'crew')
    AND pendingbot.can_view_temporary_group(id, auth.uid())
  );

DROP POLICY IF EXISTS messages_temporary_group_read ON pendingbot.messages;
CREATE POLICY messages_temporary_group_read
  ON pendingbot.messages FOR SELECT TO authenticated
  USING (pendingbot.can_view_temporary_group(conversation_id, auth.uid()));

COMMIT;
