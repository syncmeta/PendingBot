BEGIN;

-- These summary views are now read only through Edge after an explicit
-- can_view_temporary_group check. Keep the views available to service_role
-- while removing direct authenticated Data API access and making any future
-- non-service access obey the invoker's RLS context.
ALTER VIEW pendingbot.crew_resolved_responsibility_shares SET (security_invoker = on);
ALTER VIEW pendingbot.crew_link_summaries SET (security_invoker = on);

REVOKE SELECT ON pendingbot.crew_resolved_responsibility_shares FROM authenticated;
REVOKE SELECT ON pendingbot.crew_link_summaries FROM authenticated;

GRANT SELECT ON pendingbot.crew_resolved_responsibility_shares TO service_role;
GRANT SELECT ON pendingbot.crew_link_summaries TO service_role;

COMMIT;
