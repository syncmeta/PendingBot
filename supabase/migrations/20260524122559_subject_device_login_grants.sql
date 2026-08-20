-- Subject-scoped device login grants:
-- - Mac apps create short-lived QR login challenges without a user session;
-- - an already signed-in phone approves the challenge for a personal/group subject;
-- - the Mac receives a scoped device grant token, not a Supabase user JWT.

BEGIN;

SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.subject_device_login_challenges (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  challenge_secret_hash text NOT NULL,
  code text NOT NULL,
  app_kind text NOT NULL CHECK (app_kind IN ('pendingbot_macos', 'pendingcrew_macos')),
  platform text NOT NULL DEFAULT 'macos' CHECK (platform IN ('macos')),
  device_name text NOT NULL,
  device_public_key text NOT NULL,
  requested_scopes jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending',
    'approved',
    'consumed',
    'expired',
    'cancelled'
  )),
  approved_subject_id uuid REFERENCES pendingbot.subjects(id) ON DELETE SET NULL,
  approved_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  grant_kind text CHECK (grant_kind IN (
    'pendingbot_client',
    'pendingcrew_control',
    'pendingcrew_runner'
  )),
  issued_grant_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '10 minutes'),
  approved_at timestamptz,
  consumed_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS subject_device_login_challenges_secret_uniq
  ON pendingbot.subject_device_login_challenges(challenge_secret_hash);
CREATE INDEX IF NOT EXISTS subject_device_login_challenges_status_idx
  ON pendingbot.subject_device_login_challenges(status, expires_at);
CREATE INDEX IF NOT EXISTS subject_device_login_challenges_approver_idx
  ON pendingbot.subject_device_login_challenges(approved_by_user_id, created_at DESC)
  WHERE approved_by_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS pendingbot.subject_device_grants (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  granted_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  app_kind text NOT NULL CHECK (app_kind IN ('pendingbot_macos', 'pendingcrew_macos')),
  platform text NOT NULL DEFAULT 'macos' CHECK (platform IN ('macos')),
  device_name text NOT NULL,
  device_public_key text NOT NULL,
  grant_kind text NOT NULL CHECK (grant_kind IN (
    'pendingbot_client',
    'pendingcrew_control',
    'pendingcrew_runner'
  )),
  scopes jsonb NOT NULL DEFAULT '[]'::jsonb,
  token_hash text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked', 'expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  last_used_at timestamptz,
  revoked_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS subject_device_grants_token_hash_uniq
  ON pendingbot.subject_device_grants(token_hash);
CREATE INDEX IF NOT EXISTS subject_device_grants_subject_idx
  ON pendingbot.subject_device_grants(subject_id, status, created_at DESC);

ALTER TABLE pendingbot.subject_device_login_challenges
  DROP CONSTRAINT IF EXISTS subject_device_login_challenges_issued_grant_fkey;
ALTER TABLE pendingbot.subject_device_login_challenges
  ADD CONSTRAINT subject_device_login_challenges_issued_grant_fkey
  FOREIGN KEY (issued_grant_id)
  REFERENCES pendingbot.subject_device_grants(id)
  ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_authorize_device_grant(
  p_subject_id uuid,
  p_user_id uuid,
  p_grant_kind text
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
         OR (
           s.subject_type = 'group_account'
           AND (
             (
               p_grant_kind = 'pendingcrew_runner'
               AND EXISTS (
                 SELECT 1
                   FROM pendingbot.group_subject_members gsm
                  WHERE gsm.subject_id = s.id
                    AND gsm.user_id = p_user_id
                    AND gsm.can_manage_runners = true
               )
             )
             OR (
               p_grant_kind = 'pendingcrew_control'
               AND EXISTS (
                 SELECT 1
                   FROM pendingbot.group_subject_members gsm
                  WHERE gsm.subject_id = s.id
                    AND gsm.user_id = p_user_id
                    AND (gsm.role IN ('owner', 'admin') OR gsm.can_create_crew = true)
               )
             )
             OR (
               p_grant_kind = 'pendingbot_client'
               AND EXISTS (
                 SELECT 1
                   FROM pendingbot.group_subject_members gsm
                  WHERE gsm.subject_id = s.id
                    AND gsm.user_id = p_user_id
                    AND gsm.role IN ('owner', 'admin')
               )
             )
           )
         )
       )
  )
$$;

ALTER FUNCTION pendingbot.subject_can_authorize_device_grant(uuid, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.subject_can_authorize_device_grant(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.subject_can_authorize_device_grant(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.subject_can_authorize_device_grant(uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.consume_subject_device_login_challenge(
  p_challenge_id uuid,
  p_challenge_secret_hash text,
  p_grant_id uuid,
  p_token_hash text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  challenge_row pendingbot.subject_device_login_challenges%ROWTYPE;
  scopes jsonb;
BEGIN
  SELECT *
    INTO challenge_row
    FROM pendingbot.subject_device_login_challenges
   WHERE id = p_challenge_id
     AND challenge_secret_hash = p_challenge_secret_hash
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'challenge not found or invalid secret' USING ERRCODE = '42501';
  END IF;

  IF challenge_row.status IN ('pending', 'approved') AND challenge_row.expires_at <= now() THEN
    UPDATE pendingbot.subject_device_login_challenges
       SET status = 'expired'
     WHERE id = p_challenge_id;
    RAISE EXCEPTION 'challenge expired' USING ERRCODE = 'P0001';
  END IF;

  IF challenge_row.status <> 'approved' THEN
    RAISE EXCEPTION 'challenge not approved: %', challenge_row.status USING ERRCODE = 'P0001';
  END IF;

  IF challenge_row.approved_subject_id IS NULL
     OR challenge_row.approved_by_user_id IS NULL
     OR challenge_row.grant_kind IS NULL THEN
    RAISE EXCEPTION 'challenge approval incomplete' USING ERRCODE = 'P0001';
  END IF;

  scopes := COALESCE(challenge_row.requested_scopes, '[]'::jsonb);

  INSERT INTO pendingbot.subject_device_grants(
    id,
    subject_id,
    granted_by_user_id,
    app_kind,
    platform,
    device_name,
    device_public_key,
    grant_kind,
    scopes,
    token_hash,
    status
  ) VALUES (
    p_grant_id,
    challenge_row.approved_subject_id,
    challenge_row.approved_by_user_id,
    challenge_row.app_kind,
    challenge_row.platform,
    challenge_row.device_name,
    challenge_row.device_public_key,
    challenge_row.grant_kind,
    scopes,
    p_token_hash,
    'active'
  );

  UPDATE pendingbot.subject_device_login_challenges
     SET status = 'consumed',
         issued_grant_id = p_grant_id,
         consumed_at = now()
   WHERE id = p_challenge_id;

  RETURN jsonb_build_object(
    'grant_id', p_grant_id,
    'subject_id', challenge_row.approved_subject_id,
    'grant_kind', challenge_row.grant_kind,
    'scopes', scopes
  );
END $$;

ALTER FUNCTION pendingbot.consume_subject_device_login_challenge(uuid, text, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.consume_subject_device_login_challenge(uuid, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.consume_subject_device_login_challenge(uuid, text, uuid, text) TO service_role;

ALTER TABLE pendingbot.subject_device_login_challenges ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.subject_device_login_challenges TO service_role;

ALTER TABLE pendingbot.subject_device_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS subject_device_grants_subject_read ON pendingbot.subject_device_grants;
CREATE POLICY subject_device_grants_subject_read
  ON pendingbot.subject_device_grants FOR SELECT TO authenticated
  USING (pendingbot.subject_has_user_access(subject_id, auth.uid()));

GRANT SELECT ON TABLE pendingbot.subject_device_grants TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.subject_device_grants TO service_role;

COMMIT;
