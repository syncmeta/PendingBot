-- 0035_message_citations.sql — per-bubble web-search citations.
--
-- The chat bot may call search_web mid-turn. When it does, we now
-- tell the model to cite results inline as [1], [2], … and persist the
-- ordered hit list on each bubble it emits in the same turn. iOS
-- resolves the inline markers against this array to render tappable
-- citation chips. Older messages have NULL — UI falls back to plain
-- text rendering.
--
-- Shape: jsonb array of { url: text, title: text, snippet?: text }.
-- Indexed 1-based by the inline [N] markers.
ALTER TABLE pendingbot.messages
  ADD COLUMN citations jsonb;

COMMENT ON COLUMN pendingbot.messages.citations IS
  'Ordered web-search citations referenced by the assistant turn that produced this row. Array of {url,title,snippet?}; the inline [N] markers in content are 1-based indexes into it.';
