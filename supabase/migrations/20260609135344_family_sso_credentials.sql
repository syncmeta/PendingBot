-- 家族 SSO 凭据：账号级(per-user)、mint-only、换不出 session。同公司 app 共享
-- (放共享 keychain 组)，各自调 /v1/device-grant/mint 换自己 scoped 的 device-grant。
-- spec: docs/superpowers/specs/2026-06-08-pendingcrew-login-sso-design.md
BEGIN;
SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.family_sso_credentials (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL,
  device_name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked','expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '90 days'),
  last_used_at timestamptz,
  revoked_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS family_sso_credentials_token_hash_uniq
  ON pendingbot.family_sso_credentials(token_hash);
CREATE INDEX IF NOT EXISTS family_sso_credentials_user_idx
  ON pendingbot.family_sso_credentials(user_id, status, created_at DESC);

-- 子 grant 加一列：记是哪张家族凭据 mint 出来的（级联撤销用）。
ALTER TABLE pendingbot.subject_device_grants
  ADD COLUMN IF NOT EXISTS parent_family_credential_id uuid
  REFERENCES pendingbot.family_sso_credentials(id) ON DELETE SET NULL;

-- 签发家族凭据（consume / approve 路径调）。
CREATE OR REPLACE FUNCTION pendingbot.issue_family_sso_credential(
  p_id uuid, p_user_id uuid, p_token_hash text, p_device_name text
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = pendingbot, public AS $$
  INSERT INTO pendingbot.family_sso_credentials(id, user_id, token_hash, device_name)
  VALUES (p_id, p_user_id, p_token_hash, p_device_name)
  RETURNING id;
$$;
ALTER FUNCTION pendingbot.issue_family_sso_credential(uuid, uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.issue_family_sso_credential(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.issue_family_sso_credential(uuid, uuid, text, text) TO service_role;

-- 用家族凭据 mint 一张子 device-grant：校验凭据 active/未过期 → 拿 user_id →
-- 复用 subject_can_authorize_device_grant 授权检查 → 插 grant。换不出 session。
CREATE OR REPLACE FUNCTION pendingbot.mint_device_grant_from_family(
  p_family_token_hash text,
  p_grant_id uuid,
  p_token_hash text,
  p_subject_id uuid,
  p_grant_kind text,
  p_scopes jsonb,
  p_app_kind text,
  p_device_name text,
  p_device_public_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pendingbot, public AS $$
DECLARE
  fam pendingbot.family_sso_credentials%ROWTYPE;
BEGIN
  SELECT * INTO fam FROM pendingbot.family_sso_credentials
   WHERE token_hash = p_family_token_hash FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'family credential not found' USING ERRCODE = '42501';
  END IF;
  IF fam.status <> 'active' OR fam.expires_at <= now() THEN
    RAISE EXCEPTION 'family credential inactive' USING ERRCODE = 'P0001';
  END IF;
  IF p_grant_kind NOT IN ('pendingbot_client','pendingcrew_control','pendingcrew_runner') THEN
    RAISE EXCEPTION 'bad grant kind' USING ERRCODE = 'P0001';
  END IF;
  IF NOT pendingbot.subject_can_authorize_device_grant(p_subject_id, fam.user_id, p_grant_kind) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  INSERT INTO pendingbot.subject_device_grants(
    id, subject_id, granted_by_user_id, app_kind, platform,
    device_name, device_public_key, grant_kind, scopes, token_hash,
    status, parent_family_credential_id
  ) VALUES (
    p_grant_id, p_subject_id, fam.user_id, p_app_kind, 'macos',
    p_device_name, p_device_public_key, p_grant_kind, p_scopes, p_token_hash,
    'active', fam.id
  );
  UPDATE pendingbot.family_sso_credentials SET last_used_at = now() WHERE id = fam.id;

  RETURN jsonb_build_object('grant_id', p_grant_id, 'subject_id', p_subject_id,
                            'grant_kind', p_grant_kind, 'scopes', p_scopes);
END $$;
ALTER FUNCTION pendingbot.mint_device_grant_from_family(text,uuid,text,uuid,text,jsonb,text,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.mint_device_grant_from_family(text,uuid,text,uuid,text,jsonb,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.mint_device_grant_from_family(text,uuid,text,uuid,text,jsonb,text,text,text) TO service_role;

-- 撤销家族凭据 + 级联撤其 mint 出的子 grant。
CREATE OR REPLACE FUNCTION pendingbot.revoke_family_sso_credential(p_family_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pendingbot, public AS $$
BEGIN
  UPDATE pendingbot.family_sso_credentials
     SET status='revoked', revoked_at=now() WHERE id = p_family_id;
  UPDATE pendingbot.subject_device_grants
     SET status='revoked', revoked_at=now()
   WHERE parent_family_credential_id = p_family_id AND status='active';
END $$;
ALTER FUNCTION pendingbot.revoke_family_sso_credential(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.revoke_family_sso_credential(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.revoke_family_sso_credential(uuid) TO service_role;

-- consume RPC：RETURN 多带 granted_by_user_id + device_name，供 edge 在 poll
-- 成功后顺手签发家族凭据（A3）。其余逻辑与 20260524122559 原版一致。
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
    id, subject_id, granted_by_user_id, app_kind, platform,
    device_name, device_public_key, grant_kind, scopes, token_hash, status
  ) VALUES (
    p_grant_id, challenge_row.approved_subject_id, challenge_row.approved_by_user_id,
    challenge_row.app_kind, challenge_row.platform, challenge_row.device_name,
    challenge_row.device_public_key, challenge_row.grant_kind, scopes, p_token_hash, 'active'
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
    'scopes', scopes,
    'granted_by_user_id', challenge_row.approved_by_user_id,
    'device_name', challenge_row.device_name
  );
END $$;
ALTER FUNCTION pendingbot.consume_subject_device_login_challenge(uuid, text, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.consume_subject_device_login_challenge(uuid, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.consume_subject_device_login_challenge(uuid, text, uuid, text) TO service_role;

ALTER TABLE pendingbot.family_sso_credentials ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_sso_credentials_self_read ON pendingbot.family_sso_credentials;
CREATE POLICY family_sso_credentials_self_read
  ON pendingbot.family_sso_credentials FOR SELECT TO authenticated
  USING (user_id = auth.uid());
GRANT SELECT ON TABLE pendingbot.family_sso_credentials TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.family_sso_credentials TO service_role;

COMMIT;
