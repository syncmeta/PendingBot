-- 20260510151448_letters_human_kind.sql
--
-- Extends scroll_runs (the "来信" feed) so a human can write a letter to
-- another human and have it land on the recipient's 来信 tab. Until now
-- every row was bot-authored: bot reads conversation history, surfs the
-- web, writes a markdown article. We keep that path intact and add a
-- second, simpler path:
--
--   kind='bot'   → bot_id NOT NULL, author_user_id NULL
--                   (existing scroll_runs flow)
--   kind='human' → bot_id NULL, author_user_id NOT NULL
--                   (sender writes markdown directly; status='done' on
--                    insert; no progress/turns; no model spend)
--
-- For human letters, mutual friendship is required at INSERT time. We
-- enforce it via a SECURITY DEFINER helper that checks both directions of
-- pendingbot.user_contacts so the policy doesn't need to bypass RLS.
--
-- The recipient column stays as `user_id` (matches the existing realtime
-- feed filter `user_id=eq.<uid>` and the scroll_self SELECT policy).
-- Authors also get SELECT on their own outgoing letters so a future
-- "已发出" view doesn't need a second policy rewrite.

BEGIN;

-- ── 1. Schema additions ──────────────────────────────────────────────────

ALTER TABLE pendingbot.scroll_runs
    ADD COLUMN kind text NOT NULL DEFAULT 'bot',
    ADD COLUMN author_user_id uuid;

ALTER TABLE pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_author_fkey FOREIGN KEY (author_user_id)
    REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_kind_check
    CHECK (kind IN ('bot','human'));

-- bot_id was NOT NULL — relax it so kind='human' rows can exist.
ALTER TABLE pendingbot.scroll_runs
    ALTER COLUMN bot_id DROP NOT NULL;

-- Each kind has its own author/source shape. The CHECK couples them so
-- bad inserts fail loudly instead of producing dangling rows.
ALTER TABLE pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_kind_shape_check
    CHECK (
        (kind = 'bot'   AND bot_id IS NOT NULL AND author_user_id IS NULL)
     OR (kind = 'human' AND bot_id IS NULL     AND author_user_id IS NOT NULL
         AND author_user_id <> user_id)
    );

-- Index for an "outgoing letters by me" lookup (author + time desc).
-- Cheap to keep around for both kinds; bot rows simply have NULL author
-- so the partial index excludes them.
CREATE INDEX idx_scroll_runs_author
    ON pendingbot.scroll_runs (author_user_id, created_at DESC)
    WHERE author_user_id IS NOT NULL;

-- ── 2. Mutual friendship helper ──────────────────────────────────────────
-- SECURITY DEFINER so the RLS policy can call it without granting
-- user_contacts SELECT to every authenticated role beyond what 0001 set
-- up. Returns false (not error) on self / nulls so callers don't need
-- defensive guards.

CREATE OR REPLACE FUNCTION pendingbot.are_mutual_friends(a uuid, b uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
    SELECT
        a IS NOT NULL
        AND b IS NOT NULL
        AND a <> b
        AND EXISTS (
            SELECT 1 FROM pendingbot.user_contacts
            WHERE user_id = a AND contact_user_id = b
        )
        AND EXISTS (
            SELECT 1 FROM pendingbot.user_contacts
            WHERE user_id = b AND contact_user_id = a
        );
$$;

REVOKE ALL ON FUNCTION pendingbot.are_mutual_friends(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.are_mutual_friends(uuid, uuid) TO authenticated, service_role;

-- ── 3. RLS — broaden SELECT, gate INSERT for human kind ──────────────────
-- 0020 had a single owner-only SELECT (`scroll_self`). We replace it with
-- a recipient-OR-author rule so the sender can also fetch their outgoing
-- human letters (and not have its INSERT immediately fail the implicit
-- "after returning" RLS recheck).

DROP POLICY IF EXISTS scroll_self ON pendingbot.scroll_runs;

CREATE POLICY scroll_recipient_or_author ON pendingbot.scroll_runs
    FOR SELECT USING (
        user_id = auth.uid()
        OR (kind = 'human' AND author_user_id = auth.uid())
    );

-- Block direct human-letter INSERTs that aren't mutual friends. Bot
-- letters don't go through this path — the edge worker uses the service
-- role for the scroll_runs INSERT in scroll trigger handler — so this
-- policy only really fires for the future "POST /v1/scroll/letter"
-- endpoint, which calls supaUser.insert().
CREATE POLICY scroll_insert_human_mutual ON pendingbot.scroll_runs
    FOR INSERT TO authenticated
    WITH CHECK (
        kind = 'bot'
        OR (
            kind = 'human'
            AND author_user_id = auth.uid()
            AND author_user_id <> user_id
            AND pendingbot.are_mutual_friends(author_user_id, user_id)
        )
    );

-- The author should be able to cancel a stuck send (rare — letters are
-- inserted with status='done') or delete a draft they never want to land.
-- Keep recipient UPDATE/DELETE narrow for now; bot path runs as service.
CREATE POLICY scroll_author_modify ON pendingbot.scroll_runs
    FOR UPDATE TO authenticated
    USING (kind = 'human' AND author_user_id = auth.uid())
    WITH CHECK (kind = 'human' AND author_user_id = auth.uid());

CREATE POLICY scroll_author_delete ON pendingbot.scroll_runs
    FOR DELETE TO authenticated
    USING (kind = 'human' AND author_user_id = auth.uid());

COMMIT;
