-- Bubble (WeChat-style multi-bubble) output is the better default for a
-- chat product — single-block replies read like email. New user-created
-- bots now default to 'bubble'; existing rows are left untouched (flip via
-- the bot settings toggle). Mirrors the voice_call_enabled default-on move.
--
-- Preset seeds and the per-user clone functions set output_mode explicitly,
-- so this default only ever applies to bots inserted from the iOS create
-- sheet (which omits the column).

BEGIN;

ALTER TABLE pendingbot.bots
  ALTER COLUMN output_mode SET DEFAULT 'bubble';

COMMIT;
