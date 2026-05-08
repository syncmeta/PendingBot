-- 0041_envelopes_settings — ship the scroll-lab feature into production
-- (renamed to "来信"/Envelopes on the surface). Three additions:
--
--   1) scroll_runs.settings JSONB
--      What was actually used for this run — explorer model, collaborator
--      model, search provider, scrape provider, turn cap. Frozen at trigger
--      time so a later config change doesn't rewrite history.
--
--   2) scroll_runs.turns JSONB
--      Compact per-turn trace ([{i, assistantText, reasoning, toolCalls,
--      toolResults}, ...]). The runner appends after each loop iteration;
--      iOS renders the thinking process on the Envelope detail page via
--      Realtime UPDATE without polling.
--
--   3) conversations.envelope_settings JSONB
--      Per-conversation defaults the user picks in chat settings —
--      ConversationSettingsView reads/writes this directly. Trigger pulls
--      these as defaults; the trigger body can override per-call.
--
-- Schema name keeps the old `scroll_runs` table — the rename is purely UX.
-- Renaming the table would force the iOS Realtime channel filter to flip
-- and break in-flight clients during rollout.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET search_path TO pendingbot, public;

ALTER TABLE pendingbot.scroll_runs
    ADD COLUMN IF NOT EXISTS settings jsonb,
    ADD COLUMN IF NOT EXISTS turns jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE pendingbot.conversations
    ADD COLUMN IF NOT EXISTS envelope_settings jsonb;
