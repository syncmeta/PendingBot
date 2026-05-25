-- Bind SECURITY DEFINER helper functions that accept p_user_id to auth.uid().
--
-- These helpers are intentionally executable by authenticated users because RLS
-- policies call them. Without this guard, direct /rpc calls could pass another
-- user's id and probe subject, temporary-group, crew, or runner visibility.
-- Service-role calls keep working because auth.uid() is null for service role.

BEGIN;

CREATE OR REPLACE FUNCTION pendingbot.subject_has_user_access(
  p_subject_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
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

CREATE OR REPLACE FUNCTION pendingbot.subject_user_has_role(
  p_subject_id uuid,
  p_user_id uuid,
  p_roles text[]
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
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

CREATE OR REPLACE FUNCTION pendingbot.subject_can_create_crew(
  p_subject_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
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
                 AND gsm.can_create_crew = true
            )
          )
     )
$$;

CREATE OR REPLACE FUNCTION pendingbot.subject_can_manage_runners(
  p_subject_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
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

CREATE OR REPLACE FUNCTION pendingbot.subject_can_authorize_device_grant(
  p_subject_id uuid,
  p_user_id uuid,
  p_grant_kind text
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
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

CREATE OR REPLACE FUNCTION pendingbot.is_temporary_group_human_member(
  p_conversation_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.temporary_group_members tgm
        WHERE tgm.conversation_id = p_conversation_id
          AND tgm.member_kind = 'human'
          AND tgm.user_id = p_user_id
          AND tgm.status = 'active'
     )
$$;

CREATE OR REPLACE FUNCTION pendingbot.can_view_temporary_group(
  p_conversation_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
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

CREATE OR REPLACE FUNCTION pendingbot.can_view_runner_host(
  p_runner_host_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.runner_hosts rh
        WHERE rh.id = p_runner_host_id
          AND pendingbot.subject_has_user_access(rh.responsible_subject_id, p_user_id)
     )
$$;

CREATE OR REPLACE FUNCTION pendingbot.can_view_runner_lease(
  p_runner_lease_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.runner_leases rl
        WHERE rl.id = p_runner_lease_id
          AND (
            pendingbot.subject_has_user_access(rl.responsible_subject_id, p_user_id)
            OR pendingbot.can_view_crew_session(rl.crew_session_id, p_user_id)
          )
     )
$$;

CREATE OR REPLACE FUNCTION pendingbot.can_view_crew_session(
  p_crew_session_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.crew_sessions cs
        WHERE cs.id = p_crew_session_id
          AND pendingbot.can_view_temporary_group(cs.crew_conversation_id, p_user_id)
     )
$$;

CREATE OR REPLACE FUNCTION pendingbot.can_control_crew_session(
  p_crew_session_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
STABLE
AS $$
  SELECT (auth.uid() IS NULL OR p_user_id = auth.uid())
     AND EXISTS (
       SELECT 1
         FROM pendingbot.crew_sessions cs
        WHERE cs.id = p_crew_session_id
          AND pendingbot.subject_has_user_access(cs.responsible_subject_id, p_user_id)
     )
$$;

COMMIT;
