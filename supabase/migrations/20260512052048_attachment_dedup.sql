-- Content-addressable attachment dedup + bigger default quota.
--
-- Two problems the May-2026 audit follow-up flagged:
--
--   1. Re-uploading the same image (re-pick from Photos, forward
--      from another conv, screenshot copies, etc) creates a fresh
--      R2 object and a fresh `attachments` row, doubling storage
--      and double-counting against the user's quota.
--
--   2. Default per-user quota was 1 GiB which lands around ~400
--      photos — far short of a multi-year chat history.
--
-- Strategy: tag every attachment row with the SHA-256 of its body
-- (hex, 64 chars). UNIQUE on (user_id, content_sha256) — so a second
-- upload of the same bytes by the same user is a no-op at the worker
-- layer (it INSERTs against this constraint, gets back 23505, and
-- returns the existing row). Multiple users uploading the same image
-- still get separate rows (different R2 keys), which keeps RLS /
-- ownership / quota accounting per-user — full cross-user dedup
-- would need a separate `attachment_blobs` table and a reference
-- count, which is out of scope for this pass.
--
-- Bump default quota 1 GiB → 5 GiB. R2 at ~$0.015/GB/mo means
-- 5 GiB is $0.075/user/mo — negligible at this scale, and gives
-- users plenty of headroom. Per-user override path stays open via
-- a hypothetical users.attachment_quota_bytes (not added here).

BEGIN;

-- ============================================================
-- 1. Add content_sha256 column + dedup index
-- ============================================================

ALTER TABLE pendingbot.attachments
  ADD COLUMN IF NOT EXISTS content_sha256 text;

-- Per-user dedup index. Lowercase hex SHA-256 = 64 chars. Partial
-- index on NOT NULL so historical rows (pre-this-migration) don't
-- block the unique constraint while they're backfilled (or stay
-- null — they just won't dedup until re-uploaded).
CREATE UNIQUE INDEX IF NOT EXISTS idx_attachments_user_sha256
  ON pendingbot.attachments (user_id, content_sha256)
  WHERE content_sha256 IS NOT NULL;

-- ============================================================
-- 2. Bump default quota 1 GiB → 5 GiB
-- ============================================================

UPDATE pendingbot.billing_config
   SET value = to_jsonb(5368709120::bigint)        -- 5 * 1024^3
 WHERE key = 'default_attachment_quota_bytes'
   AND (value)::text::bigint = 1073741824;          -- only if still on the seed value

COMMIT;
