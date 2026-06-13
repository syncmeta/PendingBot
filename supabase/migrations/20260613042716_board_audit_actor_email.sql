-- Board console moved off the in-app Supabase login to Cloudflare Access as the
-- sole identity gate (BeyondCorp model). The board admin's identity now comes
-- from the verified Access JWT's email claim, not a Supabase auth UID — so the
-- audit actor is recorded by email, not by users.id FK.
--
-- actor_id (uuid FK → users.id) stays for legacy/historical rows; new board
-- writes leave it NULL and record actor_email instead.
ALTER TABLE pendingbot.admin_audit
    ADD COLUMN IF NOT EXISTS actor_email text;

COMMENT ON COLUMN pendingbot.admin_audit.actor_email IS
    'Cloudflare Access-authenticated email of the board admin who made the change. Set for board-console writes (actor_id NULL); legacy rows use actor_id.';
