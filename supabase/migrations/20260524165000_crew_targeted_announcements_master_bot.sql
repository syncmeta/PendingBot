-- Crew targeted announcements and master bot metadata:
-- - one canonical announcement can fan out to selected session mailboxes;
-- - Crew may record a master bot from the PendingBot side;
-- - runner sessions can announce only through their active lease.

BEGIN;

SET search_path TO pendingbot, public;

ALTER TABLE pendingbot.temporary_group_meta
  ADD COLUMN IF NOT EXISTS master_bot_id uuid REFERENCES pendingbot.bots(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS master_member_id uuid REFERENCES pendingbot.temporary_group_members(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS local_master_enabled boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS temporary_group_meta_master_bot_idx
  ON pendingbot.temporary_group_meta(master_bot_id)
  WHERE master_bot_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS pendingbot.crew_announcements (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  crew_conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  sender_kind text NOT NULL CHECK (sender_kind IN ('human', 'session', 'master_bot', 'system')),
  sender_member_id uuid REFERENCES pendingbot.temporary_group_members(id) ON DELETE SET NULL,
  sender_session_id uuid REFERENCES pendingbot.crew_sessions(id) ON DELETE SET NULL,
  source_message_id uuid REFERENCES pendingbot.messages(id) ON DELETE SET NULL,
  recipient_mode text NOT NULL DEFAULT 'all_sessions' CHECK (recipient_mode IN (
    'all_sessions',
    'mentioned_targets'
  )),
  message_kind text NOT NULL DEFAULT 'announcement' CHECK (message_kind IN (
    'announcement',
    'instruction',
    'status',
    'question',
    'handoff',
    'result',
    'blocker'
  )),
  board_visible boolean NOT NULL DEFAULT true,
  summary text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crew_announcements_sender_chk CHECK (
    (sender_kind = 'session' AND sender_session_id IS NOT NULL)
    OR
    (sender_kind IN ('human', 'master_bot') AND sender_member_id IS NOT NULL)
    OR
    (sender_kind = 'system')
  )
);

CREATE INDEX IF NOT EXISTS crew_announcements_crew_time_idx
  ON pendingbot.crew_announcements(crew_conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS crew_announcements_sender_session_idx
  ON pendingbot.crew_announcements(sender_session_id, created_at DESC)
  WHERE sender_session_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS pendingbot.crew_announcement_mentions (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  announcement_id uuid NOT NULL REFERENCES pendingbot.crew_announcements(id) ON DELETE CASCADE,
  crew_conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  responsible_subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id),
  target_kind text NOT NULL CHECK (target_kind IN ('session', 'member')),
  target_session_id uuid REFERENCES pendingbot.crew_sessions(id) ON DELETE CASCADE,
  target_member_id uuid REFERENCES pendingbot.temporary_group_members(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crew_announcement_mentions_target_chk CHECK (
    (target_kind = 'session' AND target_session_id IS NOT NULL AND target_member_id IS NULL)
    OR
    (target_kind = 'member' AND target_member_id IS NOT NULL AND target_session_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS crew_announcement_mentions_announcement_idx
  ON pendingbot.crew_announcement_mentions(announcement_id);
CREATE INDEX IF NOT EXISTS crew_announcement_mentions_target_session_idx
  ON pendingbot.crew_announcement_mentions(target_session_id, created_at DESC)
  WHERE target_session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS crew_announcement_mentions_target_member_idx
  ON pendingbot.crew_announcement_mentions(target_member_id, created_at DESC)
  WHERE target_member_id IS NOT NULL;

ALTER TABLE pendingbot.session_mailbox_items
  ADD COLUMN IF NOT EXISTS announcement_id uuid REFERENCES pendingbot.crew_announcements(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS sender_kind text,
  ADD COLUMN IF NOT EXISTS sender_member_id uuid REFERENCES pendingbot.temporary_group_members(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_message_id uuid REFERENCES pendingbot.messages(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.session_mailbox_items
  DROP CONSTRAINT IF EXISTS session_mailbox_items_message_kind_check;
ALTER TABLE pendingbot.session_mailbox_items
  ADD CONSTRAINT session_mailbox_items_message_kind_check CHECK (message_kind IN (
    'announcement',
    'instruction',
    'status',
    'question',
    'handoff',
    'result',
    'blocker'
  ));

ALTER TABLE pendingbot.session_mailbox_items
  DROP CONSTRAINT IF EXISTS session_mailbox_items_sender_kind_check;
ALTER TABLE pendingbot.session_mailbox_items
  ADD CONSTRAINT session_mailbox_items_sender_kind_check CHECK (
    sender_kind IS NULL OR sender_kind IN ('human', 'session', 'master_bot', 'system')
  );

CREATE INDEX IF NOT EXISTS session_mailbox_announcement_idx
  ON pendingbot.session_mailbox_items(announcement_id)
  WHERE announcement_id IS NOT NULL;

ALTER TABLE pendingbot.crew_announcements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crew_announcements_view ON pendingbot.crew_announcements;
CREATE POLICY crew_announcements_view
  ON pendingbot.crew_announcements FOR SELECT TO authenticated
  USING (
    pendingbot.can_view_temporary_group(crew_conversation_id, auth.uid())
    OR pendingbot.subject_has_user_access(responsible_subject_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.crew_announcements TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.crew_announcements TO service_role;

ALTER TABLE pendingbot.crew_announcement_mentions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crew_announcement_mentions_view ON pendingbot.crew_announcement_mentions;
CREATE POLICY crew_announcement_mentions_view
  ON pendingbot.crew_announcement_mentions FOR SELECT TO authenticated
  USING (
    pendingbot.can_view_temporary_group(crew_conversation_id, auth.uid())
    OR pendingbot.subject_has_user_access(responsible_subject_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.crew_announcement_mentions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.crew_announcement_mentions TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.create_crew_announcement_for_subject(
  p_crew_conversation_id uuid,
  p_responsible_subject_id uuid,
  p_actor_user_id uuid,
  p_recipient_session_ids jsonb DEFAULT '[]'::jsonb,
  p_recipient_member_ids jsonb DEFAULT '[]'::jsonb,
  p_message_kind text DEFAULT 'announcement',
  p_summary text DEFAULT '',
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_board_visible boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  meta_row pendingbot.temporary_group_meta%ROWTYPE;
  sender_member_id uuid;
  announcement_id uuid;
  summary_text text;
  recipient_session_count int := 0;
  recipient_member_count int := 0;
  valid_count int := 0;
  recipient_mode_text text;
BEGIN
  SELECT *
    INTO meta_row
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_crew_conversation_id
     AND temporary_kind = 'crew'
     AND status = 'active'
     AND responsible_subject_id = p_responsible_subject_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  IF NOT pendingbot.subject_can_create_crew(meta_row.responsible_subject_id, p_actor_user_id) THEN
    RAISE EXCEPTION 'forbidden: cannot announce for crew subject' USING ERRCODE = '42501';
  END IF;

  SELECT id
    INTO sender_member_id
    FROM pendingbot.temporary_group_members
   WHERE conversation_id = p_crew_conversation_id
     AND member_kind = 'human'
     AND user_id = p_actor_user_id
     AND status = 'active'
   ORDER BY created_at ASC
   LIMIT 1;

  IF sender_member_id IS NULL THEN
    RAISE EXCEPTION 'caller is not an active crew member' USING ERRCODE = '42501';
  END IF;

  IF p_message_kind NOT IN ('announcement', 'instruction', 'status', 'question', 'handoff', 'result', 'blocker') THEN
    RAISE EXCEPTION 'invalid message kind' USING ERRCODE = '22023';
  END IF;

  summary_text := NULLIF(trim(COALESCE(p_summary, '')), '');
  IF summary_text IS NULL THEN
    RAISE EXCEPTION 'summary required' USING ERRCODE = '22023';
  END IF;

  IF p_recipient_session_ids IS NULL OR jsonb_typeof(p_recipient_session_ids) <> 'array' THEN
    RAISE EXCEPTION 'recipient session ids must be an array' USING ERRCODE = '22023';
  END IF;
  IF p_recipient_member_ids IS NULL OR jsonb_typeof(p_recipient_member_ids) <> 'array' THEN
    RAISE EXCEPTION 'recipient member ids must be an array' USING ERRCODE = '22023';
  END IF;

  SELECT count(DISTINCT id_text)
    INTO recipient_session_count
    FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text);

  SELECT count(DISTINCT id_text)
    INTO recipient_member_count
    FROM jsonb_array_elements_text(p_recipient_member_ids) AS input(id_text);

  recipient_mode_text := CASE
    WHEN recipient_session_count = 0 AND recipient_member_count = 0 THEN 'all_sessions'
    ELSE 'mentioned_targets'
  END;

  IF recipient_session_count > 0 THEN
    SELECT count(*)
      INTO valid_count
      FROM pendingbot.crew_sessions cs
      JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text)) r
        ON cs.id = r.id_text::uuid
     WHERE cs.crew_conversation_id = p_crew_conversation_id
       AND cs.responsible_subject_id = meta_row.responsible_subject_id;

    IF valid_count <> recipient_session_count THEN
      RAISE EXCEPTION 'recipient session not found in crew' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF recipient_member_count > 0 THEN
    SELECT count(*)
      INTO valid_count
      FROM pendingbot.temporary_group_members tgm
      JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_member_ids) AS input(id_text)) r
        ON tgm.id = r.id_text::uuid
     WHERE tgm.conversation_id = p_crew_conversation_id
       AND tgm.status = 'active';

    IF valid_count <> recipient_member_count THEN
      RAISE EXCEPTION 'recipient member not found in crew' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO pendingbot.crew_announcements(
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_member_id,
    recipient_mode,
    message_kind,
    board_visible,
    summary,
    payload,
    created_by_user_id
  ) VALUES (
    p_crew_conversation_id,
    meta_row.responsible_subject_id,
    'human',
    sender_member_id,
    recipient_mode_text,
    p_message_kind,
    p_board_visible,
    summary_text,
    COALESCE(p_payload, '{}'::jsonb),
    p_actor_user_id
  )
  RETURNING id INTO announcement_id;

  INSERT INTO pendingbot.crew_announcement_mentions(
    announcement_id,
    crew_conversation_id,
    responsible_subject_id,
    target_kind,
    target_session_id
  )
  SELECT
    announcement_id,
    p_crew_conversation_id,
    meta_row.responsible_subject_id,
    'session',
    cs.id
    FROM pendingbot.crew_sessions cs
    JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text)) r
      ON cs.id = r.id_text::uuid
   WHERE cs.crew_conversation_id = p_crew_conversation_id
     AND cs.responsible_subject_id = meta_row.responsible_subject_id;

  INSERT INTO pendingbot.crew_announcement_mentions(
    announcement_id,
    crew_conversation_id,
    responsible_subject_id,
    target_kind,
    target_member_id
  )
  SELECT
    announcement_id,
    p_crew_conversation_id,
    meta_row.responsible_subject_id,
    'member',
    tgm.id
    FROM pendingbot.temporary_group_members tgm
    JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_member_ids) AS input(id_text)) r
      ON tgm.id = r.id_text::uuid
   WHERE tgm.conversation_id = p_crew_conversation_id
     AND tgm.status = 'active';

  INSERT INTO pendingbot.session_mailbox_items(
    announcement_id,
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_member_id,
    recipient_session_id,
    message_kind,
    summary,
    payload
  )
  SELECT
    announcement_id,
    p_crew_conversation_id,
    meta_row.responsible_subject_id,
    'human',
    sender_member_id,
    cs.id,
    p_message_kind,
    summary_text,
    COALESCE(p_payload, '{}'::jsonb)
    FROM pendingbot.crew_sessions cs
   WHERE cs.crew_conversation_id = p_crew_conversation_id
     AND cs.responsible_subject_id = meta_row.responsible_subject_id
     AND (
       recipient_session_count = 0 AND recipient_member_count = 0
       OR cs.id IN (
         SELECT r.id_text::uuid
           FROM (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text)) r
       )
     );

  RETURN announcement_id;
END $$;

ALTER FUNCTION pendingbot.create_crew_announcement_for_subject(uuid, uuid, uuid, jsonb, jsonb, text, text, jsonb, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_crew_announcement_for_subject(uuid, uuid, uuid, jsonb, jsonb, text, text, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_announcement_for_subject(uuid, uuid, uuid, jsonb, jsonb, text, text, jsonb, boolean) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.create_crew_announcement(
  p_crew_conversation_id uuid,
  p_recipient_session_ids jsonb DEFAULT '[]'::jsonb,
  p_recipient_member_ids jsonb DEFAULT '[]'::jsonb,
  p_message_kind text DEFAULT 'announcement',
  p_summary text DEFAULT '',
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_board_visible boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  meta_subject_id uuid;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  SELECT responsible_subject_id
    INTO meta_subject_id
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_crew_conversation_id
     AND temporary_kind = 'crew'
     AND status = 'active';

  IF meta_subject_id IS NULL THEN
    RAISE EXCEPTION 'crew not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  RETURN pendingbot.create_crew_announcement_for_subject(
    p_crew_conversation_id,
    meta_subject_id,
    caller_id,
    p_recipient_session_ids,
    p_recipient_member_ids,
    p_message_kind,
    p_summary,
    p_payload,
    p_board_visible
  );
END $$;

ALTER FUNCTION pendingbot.create_crew_announcement(uuid, jsonb, jsonb, text, text, jsonb, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_crew_announcement(uuid, jsonb, jsonb, text, text, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_announcement(uuid, jsonb, jsonb, text, text, jsonb, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION pendingbot.create_crew_announcement_from_runner_for_subject(
  p_runner_host_id uuid,
  p_responsible_subject_id uuid,
  p_crew_session_id uuid,
  p_recipient_session_ids jsonb DEFAULT '[]'::jsonb,
  p_recipient_member_ids jsonb DEFAULT '[]'::jsonb,
  p_message_kind text DEFAULT 'announcement',
  p_summary text DEFAULT '',
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_board_visible boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  session_row pendingbot.crew_sessions%ROWTYPE;
  announcement_id uuid;
  summary_text text;
  recipient_session_count int := 0;
  recipient_member_count int := 0;
  valid_count int := 0;
  recipient_mode_text text;
BEGIN
  SELECT *
    INTO session_row
    FROM pendingbot.crew_sessions
   WHERE id = p_crew_session_id
     AND responsible_subject_id = p_responsible_subject_id
     AND runner_host_id = p_runner_host_id
     AND status IN ('running', 'waiting_permission', 'blocked');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'crew session not found for runner host' USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pendingbot.runner_leases rl
     WHERE rl.crew_session_id = p_crew_session_id
       AND rl.runner_host_id = p_runner_host_id
       AND rl.responsible_subject_id = p_responsible_subject_id
       AND rl.lease_status = 'active'
       AND rl.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'forbidden: runner lease is not active' USING ERRCODE = '42501';
  END IF;

  IF p_message_kind NOT IN ('announcement', 'instruction', 'status', 'question', 'handoff', 'result', 'blocker') THEN
    RAISE EXCEPTION 'invalid message kind' USING ERRCODE = '22023';
  END IF;

  summary_text := NULLIF(trim(COALESCE(p_summary, '')), '');
  IF summary_text IS NULL THEN
    RAISE EXCEPTION 'summary required' USING ERRCODE = '22023';
  END IF;

  IF p_recipient_session_ids IS NULL OR jsonb_typeof(p_recipient_session_ids) <> 'array' THEN
    RAISE EXCEPTION 'recipient session ids must be an array' USING ERRCODE = '22023';
  END IF;
  IF p_recipient_member_ids IS NULL OR jsonb_typeof(p_recipient_member_ids) <> 'array' THEN
    RAISE EXCEPTION 'recipient member ids must be an array' USING ERRCODE = '22023';
  END IF;

  SELECT count(DISTINCT id_text)
    INTO recipient_session_count
    FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text);

  SELECT count(DISTINCT id_text)
    INTO recipient_member_count
    FROM jsonb_array_elements_text(p_recipient_member_ids) AS input(id_text);

  recipient_mode_text := CASE
    WHEN recipient_session_count = 0 AND recipient_member_count = 0 THEN 'all_sessions'
    ELSE 'mentioned_targets'
  END;

  IF recipient_session_count > 0 THEN
    SELECT count(*)
      INTO valid_count
      FROM pendingbot.crew_sessions cs
      JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text)) r
        ON cs.id = r.id_text::uuid
     WHERE cs.crew_conversation_id = session_row.crew_conversation_id
       AND cs.responsible_subject_id = session_row.responsible_subject_id;

    IF valid_count <> recipient_session_count THEN
      RAISE EXCEPTION 'recipient session not found in crew' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF recipient_member_count > 0 THEN
    SELECT count(*)
      INTO valid_count
      FROM pendingbot.temporary_group_members tgm
      JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_member_ids) AS input(id_text)) r
        ON tgm.id = r.id_text::uuid
     WHERE tgm.conversation_id = session_row.crew_conversation_id
       AND tgm.status = 'active';

    IF valid_count <> recipient_member_count THEN
      RAISE EXCEPTION 'recipient member not found in crew' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO pendingbot.crew_announcements(
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_session_id,
    recipient_mode,
    message_kind,
    board_visible,
    summary,
    payload
  ) VALUES (
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    'session',
    session_row.id,
    recipient_mode_text,
    p_message_kind,
    p_board_visible,
    summary_text,
    COALESCE(p_payload, '{}'::jsonb)
  )
  RETURNING id INTO announcement_id;

  INSERT INTO pendingbot.crew_announcement_mentions(
    announcement_id,
    crew_conversation_id,
    responsible_subject_id,
    target_kind,
    target_session_id
  )
  SELECT
    announcement_id,
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    'session',
    cs.id
    FROM pendingbot.crew_sessions cs
    JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text)) r
      ON cs.id = r.id_text::uuid
   WHERE cs.crew_conversation_id = session_row.crew_conversation_id
     AND cs.responsible_subject_id = session_row.responsible_subject_id;

  INSERT INTO pendingbot.crew_announcement_mentions(
    announcement_id,
    crew_conversation_id,
    responsible_subject_id,
    target_kind,
    target_member_id
  )
  SELECT
    announcement_id,
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    'member',
    tgm.id
    FROM pendingbot.temporary_group_members tgm
    JOIN (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_member_ids) AS input(id_text)) r
      ON tgm.id = r.id_text::uuid
   WHERE tgm.conversation_id = session_row.crew_conversation_id
     AND tgm.status = 'active';

  INSERT INTO pendingbot.session_mailbox_items(
    announcement_id,
    crew_conversation_id,
    responsible_subject_id,
    sender_kind,
    sender_session_id,
    recipient_session_id,
    message_kind,
    summary,
    payload
  )
  SELECT
    announcement_id,
    session_row.crew_conversation_id,
    session_row.responsible_subject_id,
    'session',
    session_row.id,
    cs.id,
    p_message_kind,
    summary_text,
    COALESCE(p_payload, '{}'::jsonb)
    FROM pendingbot.crew_sessions cs
   WHERE cs.crew_conversation_id = session_row.crew_conversation_id
     AND cs.responsible_subject_id = session_row.responsible_subject_id
     AND (
       recipient_session_count = 0 AND recipient_member_count = 0
       OR cs.id IN (
         SELECT r.id_text::uuid
           FROM (SELECT DISTINCT id_text FROM jsonb_array_elements_text(p_recipient_session_ids) AS input(id_text)) r
       )
     );

  INSERT INTO pendingbot.session_events(
    crew_session_id,
    event_type,
    visibility,
    summary,
    payload
  ) VALUES (
    session_row.id,
    'posted_to_crew',
    CASE WHEN p_board_visible THEN 'crew_members' ELSE 'controllers' END,
    summary_text,
    jsonb_build_object(
      'announcement_id', announcement_id,
      'recipient_session_count', recipient_session_count,
      'recipient_member_count', recipient_member_count,
      'recipient_mode', recipient_mode_text,
      'board_visible', p_board_visible
    )
  );

  UPDATE pendingbot.runner_hosts
     SET status = 'online',
         last_seen_at = now(),
         updated_at = now()
   WHERE id = p_runner_host_id
     AND responsible_subject_id = p_responsible_subject_id
     AND status <> 'disabled';

  RETURN announcement_id;
END $$;

ALTER FUNCTION pendingbot.create_crew_announcement_from_runner_for_subject(uuid, uuid, uuid, jsonb, jsonb, text, text, jsonb, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_crew_announcement_from_runner_for_subject(uuid, uuid, uuid, jsonb, jsonb, text, text, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_crew_announcement_from_runner_for_subject(uuid, uuid, uuid, jsonb, jsonb, text, text, jsonb, boolean) TO service_role;

COMMIT;
