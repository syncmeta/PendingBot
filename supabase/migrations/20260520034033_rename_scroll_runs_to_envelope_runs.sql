-- Final piece of the scroll → envelope rename: bring the storage layer
-- in line with the rest of the codebase (which already uses Envelope/
-- envelope_* in TS, Swift, and prompt IDs).
--
-- Postgres carries triggers, policies, FK constraints, and publication
-- membership across ALTER TABLE … RENAME by OID, so the only thing that
-- "breaks" is the names — we rename them explicitly here so schema.ts
-- and pg_dump don't leak the old identifier.

BEGIN;

-- ── Table ────────────────────────────────────────────────────────────
ALTER TABLE pendingbot.scroll_runs RENAME TO envelope_runs;

-- ── Constraints (PK / FK / CHECK) ────────────────────────────────────
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_pkey                   TO envelope_runs_pkey;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_status_check           TO envelope_runs_status_check;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_bot_id_fkey            TO envelope_runs_bot_id_fkey;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_conversation_id_fkey   TO envelope_runs_conversation_id_fkey;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_user_id_fkey           TO envelope_runs_user_id_fkey;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_author_fkey            TO envelope_runs_author_fkey;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_kind_check             TO envelope_runs_kind_check;
ALTER TABLE pendingbot.envelope_runs
  RENAME CONSTRAINT scroll_runs_kind_shape_check       TO envelope_runs_kind_shape_check;

-- ── Indexes ─────────────────────────────────────────────────────────
ALTER INDEX pendingbot.idx_scroll_runs_feed   RENAME TO idx_envelope_runs_feed;
ALTER INDEX pendingbot.idx_scroll_runs_conv   RENAME TO idx_envelope_runs_conv;
ALTER INDEX pendingbot.idx_scroll_runs_author RENAME TO idx_envelope_runs_author;

-- ── RLS policies ─────────────────────────────────────────────────────
ALTER POLICY scroll_recipient_or_author  ON pendingbot.envelope_runs RENAME TO envelope_recipient_or_author;
ALTER POLICY scroll_insert_human_mutual  ON pendingbot.envelope_runs RENAME TO envelope_insert_human_mutual;
ALTER POLICY scroll_author_modify        ON pendingbot.envelope_runs RENAME TO envelope_author_modify;
ALTER POLICY scroll_author_delete        ON pendingbot.envelope_runs RENAME TO envelope_author_delete;

-- audit_log.task_type is free text — historical rows stay 'scroll',
-- new rows write 'envelope' from the edge runner. iOS WalletView maps
-- both strings to the same display label.

COMMIT;
