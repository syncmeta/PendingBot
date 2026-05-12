-- Per-user cloud attachment storage cap.
--
-- Until now the only ceiling on cloud storage was per-file (MAX_UPLOAD_BYTES
-- in lib/attachments.ts). Anyone could upload indefinitely many files and
-- run up our R2 bill. Add a per-user total-bytes cap, enforced at upload
-- time by summing live attachments.byte_size.
--
-- "Live" = the attachment row still exists. Recalled / hard-deleted messages
-- will delete their attachment rows (and R2 objects) via the recall flow
-- coming in a follow-up migration, so the count naturally shrinks.
--
-- Default = 1 GiB per user (1_073_741_824 bytes). Tunable via
-- billing_config.default_attachment_quota_bytes — the existing
-- billing_config_int(...) helper reads ints from there. Per-user
-- override path can be added later (e.g. via users.attachment_quota_bytes)
-- without touching this migration's schema.
--
-- Read access: billing_config_read is currently a key allowlist (set in
-- migration 20260511160952). Add this new key to the allowed set so
-- the worker's user-scoped client can read it for the quota check.
-- (Service role reads bypass RLS regardless.)

BEGIN;

INSERT INTO pendingbot.billing_config (key, value)
VALUES ('default_attachment_quota_bytes', to_jsonb(1073741824::bigint))  -- 1 GiB
ON CONFLICT (key) DO NOTHING;

-- Replace the SELECT policy to include the new key in the allowlist.
DROP POLICY IF EXISTS billing_config_read ON pendingbot.billing_config;
CREATE POLICY billing_config_read ON pendingbot.billing_config
  FOR SELECT TO authenticated
  USING (key IN (
    'min_balance_threshold',
    'signup_bonus_credits',
    'default_attachment_quota_bytes'
  ));

-- Index to speed up SUM(byte_size) WHERE user_id = ? in the upload
-- pre-check. The existing idx_attachments_user (from
-- 20260511160952_security_rls_hardening.sql) covers the lookup, but
-- adding byte_size to a covering index lets postgres do an
-- index-only scan. INCLUDE is available since PG11.
CREATE INDEX IF NOT EXISTS idx_attachments_user_size
  ON pendingbot.attachments (user_id) INCLUDE (byte_size);

COMMIT;
