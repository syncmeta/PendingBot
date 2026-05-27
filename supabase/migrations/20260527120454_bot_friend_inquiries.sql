-- `bot_friend_inquiries` — state for the new `ask_friend` tool.
--
-- Flow:
--   1. Public bot B (`caller_bot_id`), while talking with user A
--      (`caller_conversation_id`), calls ask_friend({target_user_id,
--      question}). One row inserted here, status='open'; a bot-role
--      message is dropped into B↔target's 1v1 (`relay_conversation_id`)
--      carrying `question`. Tool returns immediately.
--   2. Target human eventually replies; B and target chat normally in
--      the relay conv. When B decides it has what it needs, it calls
--      submit_inquiry_answer({inquiry_id, answer}).
--   3. submit_inquiry_answer updates this row (answer + status). Whether
--      the answer gets injected into the caller's next turn vs. shipped
--      as a new spontaneous bot message in caller_conv is decided by
--      caller_conv's recent activity at that moment (see tool impl).
--
-- The row is the lookup key both directions: ask_friend → relay msg
-- carries inquiry_id metadata so submit_inquiry_answer can find it;
-- builder reads "answered_pending" rows for caller_conv to inject
-- pending answers into the next persona turn.

BEGIN;

CREATE TABLE pendingbot.bot_friend_inquiries (
  id                       uuid        PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  caller_bot_id            uuid        NOT NULL REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  caller_conversation_id   uuid        NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  -- The human being asked. Always the same as relay_conv.user_id but
  -- denormalized for cheap RLS / index reads.
  target_user_id           uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- 1:1 conversation between caller bot and target user that carries
  -- the actual back-and-forth. Existing conv reused when present.
  relay_conversation_id    uuid        NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  -- The bot's outreach message that kicked things off — link back so
  -- iOS can render "this turn was a friend inquiry, click to see the
  -- caller context". Nullable in case the message row gets pruned.
  relay_outreach_message_id uuid       REFERENCES pendingbot.messages(id) ON DELETE SET NULL,
  question                 text        NOT NULL,
  answer                   text,
  status                   text        NOT NULL DEFAULT 'open'
                                       CHECK (status IN (
                                         'open',
                                         -- bot called submit_inquiry_answer; caller_conv was
                                         -- "active" so the answer waits in this row for the
                                         -- builder to inject into the next persona turn.
                                         'answered_pending',
                                         -- answer already shipped as a spontaneous bot message
                                         -- in caller_conv (inactive-path) OR consumed by the
                                         -- builder and acknowledged. Terminal.
                                         'answered_delivered',
                                         -- caller side cancelled (conv deleted, bot deactivated…).
                                         'cancelled'
                                       )),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  answered_at              timestamptz
);

-- Pull-pattern: builder for caller_conv looks up rows
-- WHERE caller_conversation_id = $1 AND status = 'answered_pending'.
CREATE INDEX bot_friend_inquiries_caller_pending_idx
  ON pendingbot.bot_friend_inquiries (caller_conversation_id, status)
  WHERE status = 'answered_pending';

-- submit_inquiry_answer needs to find the row that the current
-- relay_conversation_id is bound to. We allow exactly one open inquiry
-- per relay conv at a time (so a partial unique index suffices).
CREATE UNIQUE INDEX bot_friend_inquiries_relay_open_unique
  ON pendingbot.bot_friend_inquiries (relay_conversation_id)
  WHERE status = 'open';

ALTER TABLE pendingbot.bot_friend_inquiries ENABLE ROW LEVEL SECURITY;

-- RLS: the caller user can read inquiries that fired in their own
-- conversation, and the target user can read inquiries directed to
-- them. No INSERT/UPDATE from the client — all writes go through the
-- edge worker with service role.
CREATE POLICY bot_friend_inquiries_caller_read
  ON pendingbot.bot_friend_inquiries FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pendingbot.conversations c
      WHERE c.id = caller_conversation_id AND c.user_id = auth.uid()
    )
  );

CREATE POLICY bot_friend_inquiries_target_read
  ON pendingbot.bot_friend_inquiries FOR SELECT
  USING (target_user_id = auth.uid());

CREATE OR REPLACE FUNCTION pendingbot.bot_friend_inquiries_touch_updated()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER bot_friend_inquiries_touch
  BEFORE UPDATE ON pendingbot.bot_friend_inquiries
  FOR EACH ROW EXECUTE FUNCTION pendingbot.bot_friend_inquiries_touch_updated();

GRANT SELECT ON TABLE pendingbot.bot_friend_inquiries TO authenticated;

COMMIT;
