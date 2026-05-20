-- Hide voice-call recap rows from user-facing SELECTs on messages.
--
-- The closing recap of a voice call is stored as a normal messages row
-- (role='bot', metadata.source='voice_call_summary'). It's deliberately
-- memory-only: the bot's long-term memory pipeline reads it server-side
-- (serviceClient bypasses RLS), but it must not surface to the iOS
-- client at all — not in the timeline, not in the conversation-list
-- preview, and not over the Realtime stream.
--
-- The existing 20260519090648 trigger keeps recap rows out of
-- user_unread_counts (so the conv preview doesn't update), and the iOS
-- code filters by metadata.source on history-load and realtime paths.
-- But both routes still bring the row over the wire first, and the
-- prefetch path that warms the local message cache (MessageTabView's
-- prefetchRecentMessages) wasn't filtering — so the recap landed in
-- the local SQLite cache and briefly flashed when the user opened the
-- conv before the server-side history overwrote it.
--
-- Fix at the source: restrict the SELECT policy so user JWTs (and the
-- Realtime subscription channel they back) can't see recap rows at
-- all. Service-role queries bypass RLS, so the memory pipeline is
-- unaffected.

DROP POLICY IF EXISTS messages_participant_read ON pendingbot.messages;

CREATE POLICY messages_participant_read ON pendingbot.messages
  FOR SELECT
  USING (
    pendingbot.is_participant(conversation_id)
    AND coalesce(metadata ->> 'source', '') <> 'voice_call_summary'
  );
