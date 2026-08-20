-- Close the avatar metadata leak (decisions.md D3, part 1).
--
-- The `attachments_self_read` policy had a branch that let ANY authenticated
-- user SELECT an attachment row (incl. r2_key, filename, mime, size) whenever
-- that attachment is referenced as someone's `users.avatar_path`. That made
-- avatar metadata globally readable.
--
-- This branch has NO legitimate consumer anymore:
--   • /v1/uploads/:id (byte serving) uses serviceClient + its own checks —
--     it never consults this RLS branch.
--   • /lookup returns `users.avatar_path` from the `users` table, not the
--     `attachments` row.
--   • The only client-side direct read of `attachments` (chat attachment
--     metadata in ConversationView) is gated by the message-reference branch.
-- So removing it closes the r2_key leak with no display regression.
--
-- NOTE (D3 part 2 — separate, NOT fixed here): cross-user avatar *bytes* are
-- already not served by the Worker (no avatar exception in /v1/uploads/:id),
-- so other people's uploaded avatars currently fall back to the seed
-- placeholder. Serving avatars to the two intended contexts (friend-add
-- lookup, group-member view) needs a scoped Worker path — tracked in
-- docs/decisions.md D3 / tech-debt as a design decision.

BEGIN;

DROP POLICY IF EXISTS attachments_self_read ON pendingbot.attachments;

CREATE POLICY attachments_self_read ON pendingbot.attachments
  FOR SELECT
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1
        FROM pendingbot.messages m
       WHERE m.conversation_id = attachments.conversation_id
         AND m.status <> 'deleted'
         AND m.attachments -> 'ids' ? attachments.id::text
         AND pendingbot.is_participant(m.conversation_id)
    )
  );

COMMIT;
