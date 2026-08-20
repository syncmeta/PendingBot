-- Crew DAG, captain representation, and responsibility-ratio inheritance.

BEGIN;

SET search_path TO pendingbot, public;

ALTER TABLE pendingbot.temporary_group_meta
  ADD COLUMN IF NOT EXISTS captain_bot_id uuid REFERENCES pendingbot.bots(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS runtime_kind text NOT NULL DEFAULT 'local',
  ADD COLUMN IF NOT EXISTS cloud_machine_id uuid,
  ADD COLUMN IF NOT EXISTS responsibility_mode text NOT NULL DEFAULT 'inherit';

ALTER TABLE pendingbot.temporary_group_meta
  DROP CONSTRAINT IF EXISTS temporary_group_meta_runtime_kind_chk;
ALTER TABLE pendingbot.temporary_group_meta
  ADD CONSTRAINT temporary_group_meta_runtime_kind_chk CHECK (runtime_kind IN ('local', 'cloud'));

ALTER TABLE pendingbot.temporary_group_meta
  DROP CONSTRAINT IF EXISTS temporary_group_meta_responsibility_mode_chk;
ALTER TABLE pendingbot.temporary_group_meta
  ADD CONSTRAINT temporary_group_meta_responsibility_mode_chk CHECK (responsibility_mode IN ('inherit', 'explicit'));

CREATE INDEX IF NOT EXISTS temporary_group_meta_captain_bot_idx
  ON pendingbot.temporary_group_meta(captain_bot_id)
  WHERE captain_bot_id IS NOT NULL;

ALTER TABLE pendingbot.temporary_group_members
  ADD COLUMN IF NOT EXISTS represents_crew_id uuid REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.temporary_group_members
  DROP CONSTRAINT IF EXISTS temporary_group_members_member_kind_check;
ALTER TABLE pendingbot.temporary_group_members
  ADD CONSTRAINT temporary_group_members_member_kind_check CHECK (member_kind IN (
    'human',
    'registered_bot',
    'captain',
    'ephemeral_bot',
    'code_session'
  ));

ALTER TABLE pendingbot.temporary_group_members
  DROP CONSTRAINT IF EXISTS temporary_group_members_kind_ref_chk;
ALTER TABLE pendingbot.temporary_group_members
  ADD CONSTRAINT temporary_group_members_kind_ref_chk CHECK (
    (member_kind = 'human' AND user_id IS NOT NULL AND bot_id IS NULL AND code_session_id IS NULL AND represents_crew_id IS NULL)
    OR
    (member_kind = 'registered_bot' AND bot_id IS NOT NULL AND user_id IS NULL AND code_session_id IS NULL AND represents_crew_id IS NULL)
    OR
    (member_kind = 'captain' AND bot_id IS NOT NULL AND user_id IS NULL AND code_session_id IS NULL AND represents_crew_id IS NOT NULL)
    OR
    (member_kind = 'ephemeral_bot' AND user_id IS NULL AND bot_id IS NULL AND code_session_id IS NULL AND represents_crew_id IS NULL)
    OR
    (member_kind = 'code_session' AND code_session_id IS NOT NULL AND user_id IS NULL AND bot_id IS NULL AND represents_crew_id IS NULL)
  );

CREATE UNIQUE INDEX IF NOT EXISTS temporary_group_members_active_captain_rep_uniq
  ON pendingbot.temporary_group_members(conversation_id, represents_crew_id)
  WHERE member_kind = 'captain' AND status = 'active';

CREATE TABLE IF NOT EXISTS pendingbot.crew_parent_links (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  parent_crew_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  child_crew_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  link_kind text NOT NULL DEFAULT 'parent' CHECK (link_kind IN ('parent')),
  created_by_kind text NOT NULL CHECK (created_by_kind IN ('human', 'captain')),
  created_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_bot_id uuid REFERENCES pendingbot.bots(id) ON DELETE SET NULL,
  responsibility_mode text NOT NULL DEFAULT 'inherit' CHECK (responsibility_mode IN ('inherit', 'explicit')),
  requires_human_confirmation boolean NOT NULL DEFAULT false,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (parent_crew_id, child_crew_id),
  CHECK (parent_crew_id <> child_crew_id)
);

CREATE INDEX IF NOT EXISTS crew_parent_links_parent_idx
  ON pendingbot.crew_parent_links(parent_crew_id, created_at DESC);
CREATE INDEX IF NOT EXISTS crew_parent_links_child_idx
  ON pendingbot.crew_parent_links(child_crew_id, created_at DESC);

CREATE TABLE IF NOT EXISTS pendingbot.crew_responsibility_shares (
  crew_conversation_id uuid NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  share_bps integer NOT NULL CHECK (share_bps > 0 AND share_bps <= 10000),
  source text NOT NULL DEFAULT 'explicit' CHECK (source IN ('root', 'explicit')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (crew_conversation_id, subject_id)
);

CREATE INDEX IF NOT EXISTS crew_responsibility_shares_subject_idx
  ON pendingbot.crew_responsibility_shares(subject_id, crew_conversation_id);

CREATE OR REPLACE FUNCTION pendingbot.prevent_crew_parent_cycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pendingbot, public
AS $$
BEGIN
  IF EXISTS (
    WITH RECURSIVE ancestors(id) AS (
      SELECT NEW.parent_crew_id
      UNION
      SELECT cpl.parent_crew_id
        FROM pendingbot.crew_parent_links cpl
        JOIN ancestors a ON a.id = cpl.child_crew_id
    )
    SELECT 1 FROM ancestors WHERE id = NEW.child_crew_id
  ) THEN
    RAISE EXCEPTION 'crew parent link would create a cycle' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

ALTER FUNCTION pendingbot.prevent_crew_parent_cycle() OWNER TO postgres;

DROP TRIGGER IF EXISTS crew_parent_links_prevent_cycle ON pendingbot.crew_parent_links;
CREATE TRIGGER crew_parent_links_prevent_cycle
  BEFORE INSERT OR UPDATE OF parent_crew_id, child_crew_id
  ON pendingbot.crew_parent_links
  FOR EACH ROW EXECUTE FUNCTION pendingbot.prevent_crew_parent_cycle();

CREATE OR REPLACE FUNCTION pendingbot.resolve_crew_responsibility_shares(
  p_crew_conversation_id uuid
) RETURNS TABLE(subject_id uuid, share_bps integer, source text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
DECLARE
  explicit_count integer;
  parent_count integer;
BEGIN
  SELECT count(*)
    INTO explicit_count
    FROM pendingbot.crew_responsibility_shares crs
   WHERE crs.crew_conversation_id = p_crew_conversation_id;

  IF explicit_count > 0 THEN
    RETURN QUERY
      SELECT crs.subject_id, crs.share_bps, crs.source
        FROM pendingbot.crew_responsibility_shares crs
       WHERE crs.crew_conversation_id = p_crew_conversation_id
       ORDER BY crs.subject_id;
    RETURN;
  END IF;

  SELECT count(*)
    INTO parent_count
    FROM pendingbot.crew_parent_links cpl
   WHERE cpl.child_crew_id = p_crew_conversation_id;

  IF parent_count > 0 THEN
    RETURN QUERY
      WITH inherited AS (
        SELECT r.subject_id, sum(r.share_bps)::numeric AS inherited_bps
          FROM pendingbot.crew_parent_links cpl
          CROSS JOIN LATERAL pendingbot.resolve_crew_responsibility_shares(cpl.parent_crew_id) r
         WHERE cpl.child_crew_id = p_crew_conversation_id
         GROUP BY r.subject_id
      ),
      total AS (
        SELECT nullif(sum(inherited_bps), 0) AS total_bps FROM inherited
      )
      SELECT
        inherited.subject_id,
        greatest(1, round(10000 * inherited.inherited_bps / total.total_bps)::integer) AS share_bps,
        'inherited'::text AS source
      FROM inherited, total
      WHERE total.total_bps IS NOT NULL
      ORDER BY inherited.subject_id;
    RETURN;
  END IF;

  RETURN QUERY
    SELECT tgm.responsible_subject_id, 10000, 'legacy'::text
      FROM pendingbot.temporary_group_meta tgm
     WHERE tgm.conversation_id = p_crew_conversation_id
       AND tgm.temporary_kind = 'crew';
END $$;

ALTER FUNCTION pendingbot.resolve_crew_responsibility_shares(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.resolve_crew_responsibility_shares(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.resolve_crew_responsibility_shares(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.resolve_crew_responsibility_shares(uuid) TO service_role;

CREATE OR REPLACE VIEW pendingbot.crew_resolved_responsibility_shares AS
  SELECT
    tgm.conversation_id AS crew_conversation_id,
    resolved.subject_id,
    resolved.share_bps,
    resolved.source
  FROM pendingbot.temporary_group_meta tgm
  CROSS JOIN LATERAL pendingbot.resolve_crew_responsibility_shares(tgm.conversation_id) resolved
  WHERE tgm.temporary_kind = 'crew';

ALTER VIEW pendingbot.crew_resolved_responsibility_shares OWNER TO postgres;
GRANT SELECT ON pendingbot.crew_resolved_responsibility_shares TO authenticated;
GRANT SELECT ON pendingbot.crew_resolved_responsibility_shares TO service_role;

CREATE OR REPLACE VIEW pendingbot.crew_link_summaries AS
  SELECT
    cpl.child_crew_id AS current_crew_id,
    cpl.parent_crew_id AS linked_crew_id,
    'parent'::text AS direction,
    COALESCE(parent_meta.title, parent_conv.title, 'Crew') AS title,
    parent_meta.status,
    parent_meta.runtime_kind,
    parent_meta.captain_bot_id,
    parent_member.id AS captain_member_id,
    cpl.created_at
  FROM pendingbot.crew_parent_links cpl
  JOIN pendingbot.temporary_group_meta parent_meta
    ON parent_meta.conversation_id = cpl.parent_crew_id
   AND parent_meta.temporary_kind = 'crew'
  JOIN pendingbot.conversations parent_conv
    ON parent_conv.id = cpl.parent_crew_id
  LEFT JOIN pendingbot.temporary_group_members parent_member
    ON parent_member.conversation_id = cpl.parent_crew_id
   AND parent_member.member_kind = 'captain'
   AND parent_member.represents_crew_id = cpl.child_crew_id
   AND parent_member.status = 'active'
  UNION ALL
  SELECT
    cpl.parent_crew_id AS current_crew_id,
    cpl.child_crew_id AS linked_crew_id,
    'child'::text AS direction,
    COALESCE(child_meta.title, child_conv.title, 'Crew') AS title,
    child_meta.status,
    child_meta.runtime_kind,
    child_meta.captain_bot_id,
    child_member.id AS captain_member_id,
    cpl.created_at
  FROM pendingbot.crew_parent_links cpl
  JOIN pendingbot.temporary_group_meta child_meta
    ON child_meta.conversation_id = cpl.child_crew_id
   AND child_meta.temporary_kind = 'crew'
  JOIN pendingbot.conversations child_conv
    ON child_conv.id = cpl.child_crew_id
  LEFT JOIN pendingbot.temporary_group_members child_member
    ON child_member.conversation_id = cpl.parent_crew_id
   AND child_member.member_kind = 'captain'
   AND child_member.represents_crew_id = cpl.child_crew_id
   AND child_member.status = 'active';

ALTER VIEW pendingbot.crew_link_summaries OWNER TO postgres;
GRANT SELECT ON pendingbot.crew_link_summaries TO authenticated;
GRANT SELECT ON pendingbot.crew_link_summaries TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.user_can_control_crew_by_responsibility(
  p_crew_conversation_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.resolve_crew_responsibility_shares(p_crew_conversation_id) r
     WHERE pendingbot.subject_has_user_access(r.subject_id, p_user_id)
  )
$$;

ALTER FUNCTION pendingbot.user_can_control_crew_by_responsibility(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.user_can_control_crew_by_responsibility(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.user_can_control_crew_by_responsibility(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.user_can_control_crew_by_responsibility(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_actor(
  p_parent_crew_conversation_id uuid,
  p_actor_user_id uuid,
  p_title text DEFAULT '',
  p_created_by_kind text DEFAULT 'human',
  p_created_by_bot_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  parent_meta pendingbot.temporary_group_meta%ROWTYPE;
  child_id uuid;
  title_text text;
  member_id uuid;
BEGIN
  SELECT *
    INTO parent_meta
    FROM pendingbot.temporary_group_meta
   WHERE conversation_id = p_parent_crew_conversation_id
     AND temporary_kind = 'crew'
     AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'parent crew not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'actor required' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.user_can_control_crew_by_responsibility(p_parent_crew_conversation_id, p_actor_user_id) THEN
    RAISE EXCEPTION 'forbidden: cannot create child crew for parent responsibility' USING ERRCODE = '42501';
  END IF;

  title_text := NULLIF(trim(COALESCE(p_title, '')), '');
  IF title_text IS NULL THEN
    title_text := '机组';
  END IF;

  INSERT INTO pendingbot.conversations(
    conversation_type,
    feature,
    user_id,
    bot_id,
    title,
    metadata
  ) VALUES (
    'crew',
    'message',
    p_actor_user_id,
    NULL,
    title_text,
    jsonb_build_object('surface', 'crew', 'parentCrewId', p_parent_crew_conversation_id)
  )
  RETURNING id INTO child_id;

  INSERT INTO pendingbot.temporary_group_meta(
    conversation_id,
    temporary_kind,
    responsible_subject_id,
    initiator_type,
    initiator_user_id,
    source_conversation_id,
    parent_temporary_group_id,
    root_temporary_group_id,
    title,
    runtime_kind,
    responsibility_mode
  ) VALUES (
    child_id,
    'crew',
    parent_meta.responsible_subject_id,
    'human',
    p_actor_user_id,
    p_parent_crew_conversation_id,
    p_parent_crew_conversation_id,
    COALESCE(parent_meta.root_temporary_group_id, p_parent_crew_conversation_id),
    title_text,
    parent_meta.runtime_kind,
    'inherit'
  );

  INSERT INTO pendingbot.crew_parent_links(
    parent_crew_id,
    child_crew_id,
    created_by_kind,
    created_by_user_id,
    created_by_bot_id,
    responsibility_mode
  ) VALUES (
    p_parent_crew_conversation_id,
    child_id,
    p_created_by_kind,
    CASE WHEN p_created_by_kind = 'human' THEN p_actor_user_id ELSE NULL END,
    CASE WHEN p_created_by_kind = 'captain' THEN p_created_by_bot_id ELSE NULL END,
    'inherit'
  );

  INSERT INTO pendingbot.temporary_group_members(
    conversation_id,
    member_kind,
    user_id,
    display_name,
    role,
    capabilities
  )
  SELECT
    child_id,
    'human',
    p_actor_user_id,
    COALESCE(NULLIF(u.display_name, ''), u.email, '你'),
    'owner',
    jsonb_build_object('can_create_session', true, 'can_manage_crew', true)
    FROM pendingbot.users u
   WHERE u.id = p_actor_user_id
  RETURNING id INTO member_id;

  IF member_id IS NULL THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.conversation_participants(
    conversation_id,
    participant_type,
    participant_id,
    role
  ) VALUES (
    child_id,
    'user',
    p_actor_user_id,
    'owner'
  )
  ON CONFLICT DO NOTHING;

  RETURN child_id;
END $$;

ALTER FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_actor(uuid, uuid, text, text, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_actor(uuid, uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_actor(uuid, uuid, text, text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.create_child_crew_inheriting_responsibility(
  p_parent_crew_conversation_id uuid,
  p_title text DEFAULT ''
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;
  RETURN pendingbot.create_child_crew_inheriting_responsibility_for_actor(
    p_parent_crew_conversation_id,
    caller_id,
    p_title,
    'human',
    NULL
  );
END $$;

ALTER FUNCTION pendingbot.create_child_crew_inheriting_responsibility(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_child_crew_inheriting_responsibility(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_child_crew_inheriting_responsibility(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_subject(
  p_parent_crew_conversation_id uuid,
  p_granted_subject_id uuid,
  p_actor_user_id uuid,
  p_title text DEFAULT ''
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pendingbot.resolve_crew_responsibility_shares(p_parent_crew_conversation_id) r
     WHERE r.subject_id = p_granted_subject_id
  ) THEN
    RAISE EXCEPTION 'forbidden: granted subject is not in parent responsibility split' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.subject_has_user_access(p_granted_subject_id, p_actor_user_id) THEN
    RAISE EXCEPTION 'forbidden: actor cannot control granted subject' USING ERRCODE = '42501';
  END IF;

  RETURN pendingbot.create_child_crew_inheriting_responsibility_for_actor(
    p_parent_crew_conversation_id,
    p_actor_user_id,
    p_title,
    'human',
    NULL
  );
END $$;

ALTER FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_subject(uuid, uuid, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_subject(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.create_child_crew_inheriting_responsibility_for_subject(uuid, uuid, uuid, text) TO service_role;

ALTER TABLE pendingbot.crew_parent_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crew_parent_links_view ON pendingbot.crew_parent_links;
CREATE POLICY crew_parent_links_view
  ON pendingbot.crew_parent_links FOR SELECT TO authenticated
  USING (
    pendingbot.can_view_temporary_group(parent_crew_id, auth.uid())
    OR pendingbot.can_view_temporary_group(child_crew_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.crew_parent_links TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.crew_parent_links TO service_role;

ALTER TABLE pendingbot.crew_responsibility_shares ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS crew_responsibility_shares_view ON pendingbot.crew_responsibility_shares;
CREATE POLICY crew_responsibility_shares_view
  ON pendingbot.crew_responsibility_shares FOR SELECT TO authenticated
  USING (pendingbot.can_view_temporary_group(crew_conversation_id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.crew_responsibility_shares TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.crew_responsibility_shares TO service_role;

COMMIT;
