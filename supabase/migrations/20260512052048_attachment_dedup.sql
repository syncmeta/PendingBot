-- Content-addressable per-user attachment dedup.
--
-- Re-uploading the same image (re-pick from Photos, forward from
-- another conv, screenshot copies, etc) used to create a fresh R2
-- object and a fresh `attachments` row, doubling storage and
-- double-counting against the user's quota. Adding SHA-256 content
-- addressing collapses identical-bytes uploads from the same user
-- into one row.
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

BEGIN;

-- Add content_sha256 column + dedup index.

ALTER TABLE pendingbot.attachments
  ADD COLUMN IF NOT EXISTS content_sha256 text;

-- Per-user dedup index. Lowercase hex SHA-256 = 64 chars. Partial
-- index on NOT NULL so historical rows (pre-this-migration) don't
-- block the unique constraint while they're backfilled (or stay
-- null — they just won't dedup until re-uploaded).
CREATE UNIQUE INDEX IF NOT EXISTS idx_attachments_user_sha256
  ON pendingbot.attachments (user_id, content_sha256)
  WHERE content_sha256 IS NOT NULL;

COMMIT;
