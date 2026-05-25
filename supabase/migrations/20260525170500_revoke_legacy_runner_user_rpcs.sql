-- Runner execution is now device-grant only. These early user-JWT RPCs were
-- useful while PendingCrew auth was being bootstrapped, but they expose runner
-- registration/heartbeat/claim/event/finish operations directly through
-- PostgREST for any user who can manage a subject. The Worker now uses the
-- subject-scoped service-role path for runner mutations.

BEGIN;

REVOKE EXECUTE ON FUNCTION pendingbot.register_runner_host(uuid, text, jsonb, jsonb)
  FROM authenticated, anon, public;

REVOKE EXECUTE ON FUNCTION pendingbot.runner_host_heartbeat(uuid, jsonb, jsonb)
  FROM authenticated, anon, public;

REVOKE EXECUTE ON FUNCTION pendingbot.claim_next_crew_session(uuid, jsonb)
  FROM authenticated, anon, public;

REVOKE EXECUTE ON FUNCTION pendingbot.append_crew_session_event_from_runner(
  uuid, uuid, text, text, text, jsonb, text
) FROM authenticated, anon, public;

REVOKE EXECUTE ON FUNCTION pendingbot.finish_crew_session_from_runner(
  uuid, uuid, text, text, jsonb, text
) FROM authenticated, anon, public;

COMMIT;
