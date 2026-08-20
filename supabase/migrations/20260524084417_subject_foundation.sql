-- Subject foundation:
-- - user_account / group_account responsibility subjects;
-- - subject-scoped wallet compatibility layer;
-- - group subject membership controls;
-- - helper RPCs used by Edge and future Crew/temporary-group work.

BEGIN;

SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.subjects (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  subject_type text NOT NULL CHECK (subject_type IN ('user_account', 'group_account')),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  group_conversation_id uuid REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subjects_user_kind_chk CHECK (
    (subject_type = 'user_account' AND user_id IS NOT NULL AND group_conversation_id IS NULL)
    OR
    (subject_type = 'group_account' AND user_id IS NULL AND group_conversation_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS subjects_user_account_uniq
  ON pendingbot.subjects(user_id)
  WHERE subject_type = 'user_account';

CREATE UNIQUE INDEX IF NOT EXISTS subjects_group_account_uniq
  ON pendingbot.subjects(group_conversation_id)
  WHERE subject_type = 'group_account';

CREATE TABLE IF NOT EXISTS pendingbot.subject_wallets (
  subject_id uuid PRIMARY KEY REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  balance_credits bigint NOT NULL DEFAULT 0,
  lifetime_topup_credits bigint NOT NULL DEFAULT 0,
  lifetime_spent_credits bigint NOT NULL DEFAULT 0,
  balance_updated_at timestamptz
);

CREATE TABLE IF NOT EXISTS pendingbot.group_subject_members (
  subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  can_manage_wallet boolean NOT NULL DEFAULT false,
  can_manage_runners boolean NOT NULL DEFAULT false,
  can_create_crew boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (subject_id, user_id)
);

CREATE INDEX IF NOT EXISTS group_subject_members_user_idx
  ON pendingbot.group_subject_members(user_id);

CREATE OR REPLACE FUNCTION pendingbot.subject_has_user_access(
  p_subject_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.subjects s
     WHERE s.id = p_subject_id
       AND s.status = 'active'
       AND (
         (s.subject_type = 'user_account' AND s.user_id = p_user_id)
         OR EXISTS (
           SELECT 1
             FROM pendingbot.group_subject_members gsm
            WHERE gsm.subject_id = s.id
              AND gsm.user_id = p_user_id
         )
       )
  )
$$;

ALTER FUNCTION pendingbot.subject_has_user_access(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.subject_has_user_access(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.subject_has_user_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.subject_has_user_access(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.subject_user_has_role(
  p_subject_id uuid,
  p_user_id uuid,
  p_roles text[]
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.group_subject_members gsm
      JOIN pendingbot.subjects s
        ON s.id = gsm.subject_id
     WHERE gsm.subject_id = p_subject_id
       AND gsm.user_id = p_user_id
       AND gsm.role = ANY(p_roles)
       AND s.status = 'active'
  )
$$;

ALTER FUNCTION pendingbot.subject_user_has_role(uuid, uuid, text[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.subject_user_has_role(uuid, uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.subject_user_has_role(uuid, uuid, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.subject_user_has_role(uuid, uuid, text[]) TO service_role;

ALTER TABLE pendingbot.subjects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subjects_self_read ON pendingbot.subjects;
CREATE POLICY subjects_self_read
  ON pendingbot.subjects FOR SELECT TO authenticated
  USING (
    (subject_type = 'user_account' AND user_id = auth.uid())
    OR pendingbot.subject_has_user_access(id, auth.uid())
  );

GRANT SELECT ON TABLE pendingbot.subjects TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.subjects TO service_role;

ALTER TABLE pendingbot.subject_wallets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subject_wallets_subject_read ON pendingbot.subject_wallets;
CREATE POLICY subject_wallets_subject_read
  ON pendingbot.subject_wallets FOR SELECT TO authenticated
  USING (pendingbot.subject_has_user_access(subject_id, auth.uid()));

GRANT SELECT ON TABLE pendingbot.subject_wallets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.subject_wallets TO service_role;

ALTER TABLE pendingbot.group_subject_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS group_subject_members_self_read ON pendingbot.group_subject_members;
CREATE POLICY group_subject_members_self_read
  ON pendingbot.group_subject_members FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS group_subject_members_admin_read ON pendingbot.group_subject_members;
CREATE POLICY group_subject_members_admin_read
  ON pendingbot.group_subject_members FOR SELECT TO authenticated
  USING (pendingbot.subject_user_has_role(subject_id, auth.uid(), ARRAY['owner', 'admin']));

GRANT SELECT ON TABLE pendingbot.group_subject_members TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.group_subject_members TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.ensure_user_subject(
  p_user_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_subject_id uuid;
  v_display_name text;
  v_balance bigint;
  v_lifetime_topup bigint;
  v_lifetime_spent bigint;
  v_balance_updated_at timestamptz;
BEGIN
  SELECT
    COALESCE(NULLIF(display_name, ''), email, '你'),
    balance_credits,
    lifetime_topup_credits,
    lifetime_spent_credits,
    balance_updated_at
    INTO v_display_name, v_balance, v_lifetime_topup, v_lifetime_spent, v_balance_updated_at
    FROM pendingbot.users
   WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.subjects(subject_type, user_id, display_name)
  VALUES ('user_account', p_user_id, v_display_name)
  ON CONFLICT (user_id) WHERE subject_type = 'user_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  INSERT INTO pendingbot.subject_wallets(
    subject_id,
    balance_credits,
    lifetime_topup_credits,
    lifetime_spent_credits,
    balance_updated_at
  ) VALUES (
    v_subject_id,
    COALESCE(v_balance, 0),
    COALESCE(v_lifetime_topup, 0),
    COALESCE(v_lifetime_spent, 0),
    v_balance_updated_at
  )
  ON CONFLICT (subject_id) DO UPDATE SET
    balance_credits = EXCLUDED.balance_credits,
    lifetime_topup_credits = EXCLUDED.lifetime_topup_credits,
    lifetime_spent_credits = EXCLUDED.lifetime_spent_credits,
    balance_updated_at = EXCLUDED.balance_updated_at;

  RETURN v_subject_id;
END $$;

ALTER FUNCTION pendingbot.ensure_user_subject(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.ensure_user_subject(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.ensure_user_subject(uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.ensure_group_subject_for_conversation(
  p_conversation_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_subject_id uuid;
  v_title text;
  v_creator uuid;
BEGIN
  SELECT
    COALESCE(NULLIF(cgm.title, ''), NULLIF(c.title, ''), '群账号'),
    cgm.created_by
    INTO v_title, v_creator
    FROM pendingbot.conversations c
    LEFT JOIN pendingbot.conversation_group_meta cgm
      ON cgm.conversation_id = c.id
   WHERE c.id = p_conversation_id
     AND c.conversation_type = 'group';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group conversation not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.subjects(subject_type, group_conversation_id, display_name)
  VALUES ('group_account', p_conversation_id, v_title)
  ON CONFLICT (group_conversation_id) WHERE subject_type = 'group_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  INSERT INTO pendingbot.subject_wallets(subject_id)
  VALUES (v_subject_id)
  ON CONFLICT (subject_id) DO NOTHING;

  IF v_creator IS NOT NULL THEN
    INSERT INTO pendingbot.group_subject_members(
      subject_id,
      user_id,
      role,
      can_manage_wallet,
      can_manage_runners,
      can_create_crew
    ) VALUES (
      v_subject_id,
      v_creator,
      'owner',
      true,
      true,
      true
    )
    ON CONFLICT (subject_id, user_id) DO UPDATE SET
      role = CASE
        WHEN pendingbot.group_subject_members.role = 'owner' THEN 'owner'
        ELSE EXCLUDED.role
      END,
      can_manage_wallet = pendingbot.group_subject_members.can_manage_wallet OR EXCLUDED.can_manage_wallet,
      can_manage_runners = pendingbot.group_subject_members.can_manage_runners OR EXCLUDED.can_manage_runners,
      can_create_crew = pendingbot.group_subject_members.can_create_crew OR EXCLUDED.can_create_crew;
  END IF;

  RETURN v_subject_id;
END $$;

ALTER FUNCTION pendingbot.ensure_group_subject_for_conversation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.ensure_group_subject_for_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.ensure_group_subject_for_conversation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.billing_debit_subject(
  p_subject_id uuid,
  p_audit_log_id uuid,
  p_credits bigint
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_new_balance bigint;
BEGIN
  IF p_credits <= 0 THEN
    UPDATE pendingbot.audit_log
       SET billing_status = 'skipped'
     WHERE id = p_audit_log_id;

    SELECT balance_credits INTO v_new_balance
      FROM pendingbot.subject_wallets
     WHERE subject_id = p_subject_id;

    RETURN v_new_balance;
  END IF;

  UPDATE pendingbot.subject_wallets
     SET balance_credits = balance_credits - p_credits,
         lifetime_spent_credits = lifetime_spent_credits + p_credits,
         balance_updated_at = now()
   WHERE subject_id = p_subject_id
  RETURNING balance_credits INTO v_new_balance;

  IF NOT FOUND THEN
    UPDATE pendingbot.audit_log
       SET billing_status = 'unbilled'
     WHERE id = p_audit_log_id;
    RETURN NULL;
  END IF;

  UPDATE pendingbot.audit_log
     SET billing_status = CASE WHEN v_new_balance < 0 THEN 'unbilled' ELSE 'billed' END
   WHERE id = p_audit_log_id;

  RETURN v_new_balance;
END $$;

ALTER FUNCTION pendingbot.billing_debit_subject(uuid, uuid, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.billing_debit_subject(uuid, uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.billing_debit_subject(uuid, uuid, bigint) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.tg_users_ensure_subject()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
BEGIN
  PERFORM pendingbot.ensure_user_subject(NEW.id);
  RETURN NEW;
END $$;

ALTER FUNCTION pendingbot.tg_users_ensure_subject() OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.tg_users_ensure_subject() FROM PUBLIC;

DROP TRIGGER IF EXISTS users_ensure_subject_trg ON pendingbot.users;
CREATE TRIGGER users_ensure_subject_trg
AFTER INSERT OR UPDATE OF display_name, email, balance_credits, lifetime_topup_credits, lifetime_spent_credits, balance_updated_at
ON pendingbot.users
FOR EACH ROW
EXECUTE FUNCTION pendingbot.tg_users_ensure_subject();

INSERT INTO pendingbot.subjects(subject_type, user_id, display_name)
SELECT 'user_account', u.id, COALESCE(NULLIF(u.display_name, ''), u.email, '你')
  FROM pendingbot.users u
ON CONFLICT (user_id) WHERE subject_type = 'user_account'
DO UPDATE SET
  display_name = EXCLUDED.display_name,
  updated_at = now();

INSERT INTO pendingbot.subject_wallets(
  subject_id,
  balance_credits,
  lifetime_topup_credits,
  lifetime_spent_credits,
  balance_updated_at
)
SELECT
  s.id,
  u.balance_credits,
  u.lifetime_topup_credits,
  u.lifetime_spent_credits,
  u.balance_updated_at
  FROM pendingbot.subjects s
  JOIN pendingbot.users u
    ON u.id = s.user_id
 WHERE s.subject_type = 'user_account'
ON CONFLICT (subject_id) DO UPDATE SET
  balance_credits = EXCLUDED.balance_credits,
  lifetime_topup_credits = EXCLUDED.lifetime_topup_credits,
  lifetime_spent_credits = EXCLUDED.lifetime_spent_credits,
  balance_updated_at = EXCLUDED.balance_updated_at;

COMMIT;
