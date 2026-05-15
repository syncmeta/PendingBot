-- The chat agent's execute_code tool moved off Daytona onto the Cloudflare
-- Sandbox SDK (apps/edge/src/lib/sandbox.ts). Sandboxes are now keyed by
-- conversation_id at the binding level (`getSandbox(env.Sandbox, id)`),
-- and the SDK auto-sleeps idle containers — neither the per-conversation
-- bookkeeping (daytona_sandbox_id, bootstrapped) nor the cron-driven
-- last_used_at sweep has any reader left in the codebase.
--
-- Drop the table; the original definition lives in
-- supabase/migrations/0027_bot_sandbox_sessions.sql for history.

BEGIN;

DROP TABLE IF EXISTS pendingbot.bot_sandbox_sessions;

COMMIT;
