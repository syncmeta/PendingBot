-- Tighten attachment metadata visibility.
--
-- Raw bytes are already Worker-gated by uploader OR current participant of a
-- non-deleted message referencing the attachment. Keep the DB metadata policy
-- aligned with that model so filenames, summaries, tags, and r2_key do not
-- remain visible merely because attachments.conversation_id is set.

BEGIN;

DROP POLICY IF EXISTS attachments_self_read ON pendingbot.attachments;

CREATE POLICY attachments_self_read ON pendingbot.attachments
  FOR SELECT
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1
        FROM pendingbot.users u
       WHERE u.avatar_path = attachments.id::text
    )
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
