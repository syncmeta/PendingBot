-- Runner host RPCs:
-- - subject-scoped permission check for runner management;
-- - macOS runner registration and heartbeat.

BEGIN;

SET search_path TO pendingbot, public;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_manage_runners(
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
              AND gsm.can_manage_runners = true
         )
       )
  )
$$;

ALTER FUNCTION pendingbot.subject_can_manage_runners(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.subject_can_manage_runners(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.subject_can_manage_runners(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.subject_can_manage_runners(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.register_runner_host(
  p_responsible_subject_id uuid,
  p_display_name text,
  p_capabilities jsonb DEFAULT '{}'::jsonb,
  p_allowed_runner_kinds jsonb DEFAULT '[]'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  host_id uuid;
  display_text text;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  IF NOT pendingbot.subject_can_manage_runners(p_responsible_subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot manage runners for subject' USING ERRCODE = '42501';
  END IF;

  display_text := NULLIF(trim(COALESCE(p_display_name, '')), '');
  IF display_text IS NULL THEN
    display_text := 'Mac Runner';
  END IF;

  INSERT INTO pendingbot.runner_hosts(
    responsible_subject_id,
    platform,
    display_name,
    capabilities,
    allowed_runner_kinds,
    status,
    last_seen_at
  ) VALUES (
    p_responsible_subject_id,
    'macos',
    display_text,
    COALESCE(p_capabilities, '{}'::jsonb),
    COALESCE(p_allowed_runner_kinds, '[]'::jsonb),
    'online',
    now()
  )
  RETURNING id INTO host_id;

  RETURN host_id;
END $$;

ALTER FUNCTION pendingbot.register_runner_host(uuid, text, jsonb, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.register_runner_host(uuid, text, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.register_runner_host(uuid, text, jsonb, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION pendingbot.runner_host_heartbeat(
  p_runner_host_id uuid,
  p_capabilities jsonb DEFAULT NULL,
  p_allowed_runner_kinds jsonb DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
DECLARE
  caller_id uuid := auth.uid();
  subject_id uuid;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '42501';
  END IF;

  SELECT responsible_subject_id
    INTO subject_id
    FROM pendingbot.runner_hosts
   WHERE id = p_runner_host_id;

  IF subject_id IS NULL THEN
    RAISE EXCEPTION 'runner host not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT pendingbot.subject_can_manage_runners(subject_id, caller_id) THEN
    RAISE EXCEPTION 'forbidden: cannot manage runner host' USING ERRCODE = '42501';
  END IF;

  UPDATE pendingbot.runner_hosts
     SET status = CASE WHEN status = 'disabled' THEN 'disabled' ELSE 'online' END,
         last_seen_at = now(),
         updated_at = now(),
         capabilities = COALESCE(p_capabilities, capabilities),
         allowed_runner_kinds = COALESCE(p_allowed_runner_kinds, allowed_runner_kinds)
   WHERE id = p_runner_host_id;

  RETURN true;
END $$;

ALTER FUNCTION pendingbot.runner_host_heartbeat(uuid, jsonb, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.runner_host_heartbeat(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.runner_host_heartbeat(uuid, jsonb, jsonb) TO authenticated;

COMMIT;
