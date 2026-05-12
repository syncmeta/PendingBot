-- Tighten attachments visibility to strict scope: an attachment is
-- visible only to its uploader; cross-user visibility happens via the
-- worker (GET /v1/uploads/:id) which gates on current conversation
-- membership + message-not-recalled.
--
-- Before: attachments_self_read used
--   (user_id = auth.uid()) OR is_participant(conversation_id)
-- which meant any current/historical participant of the conversation
-- could read every attachment ever uploaded by anyone — even after the
-- attachment's message was deleted and even after the reader left the
-- group, as long as they kept the attachment id.
--
-- After:
--   • RLS SELECT is uploader-only (user_id = auth.uid()).
--   • The worker's GET /v1/uploads/:id route does an explicit
--     server-side membership + not-deleted check via service role
--     (see apps/edge/src/routes/upload.ts). This lets group bots
--     and current participants still see attachments through the
--     worker without granting blanket DB read access — and it
--     respects message recall: once a message's status is 'deleted'
--     the worker route stops serving its attachments.

BEGIN;

DROP POLICY IF EXISTS attachments_self_read ON pendingbot.attachments;
CREATE POLICY attachments_self_read ON pendingbot.attachments
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

COMMIT;
