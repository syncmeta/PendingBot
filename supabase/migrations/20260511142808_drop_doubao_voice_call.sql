-- Drop the Doubao voice-call surface that was added in
-- 20260511071702_realtime_voice_calls.sql. We're keeping only the
-- OpenAI Realtime path going forward — the Doubao SDK + WebSocket-proxy
-- alternatives both come with downsides we don't want to live with:
--
--   * SpeechEngineToB SDK path leaks the system prompt + long-lived
--     AccessToken to the device.
--   * Worker-proxy path (DurableObject relaying the binary WS protocol
--     to wss://openspeech.bytedance.com) means CF Worker bandwidth +
--     custom binary codec maintenance for a feature we don't have a
--     business case for yet.
--
-- Removed in this migration:
--   * bots.voice_call_provider column (single-provider now)
--   * llm_model_aliases.audio_per_minute_price column (Doubao-only price dim)
--   * audit_log.audio_seconds_billed column (Doubao-only usage dim)
--   * seeded doubao-realtime model, doubao provider, and their alias

-- 1. drop the doubao alias first so the FK to the model + provider rows
-- can release.
delete from pendingbot.llm_model_aliases
 where provider_id = (
   select id from pendingbot.llm_providers where slug = 'doubao'
 );

-- 2. drop the model + provider rows.
delete from pendingbot.llm_models    where slug = 'doubao-realtime';
delete from pendingbot.llm_providers where slug = 'doubao';

-- 3. drop the doubao-only columns. IF EXISTS keeps the migration
-- idempotent if it runs against an env that already had the columns
-- pruned manually.
alter table pendingbot.llm_model_aliases
  drop column if exists audio_per_minute_price;

alter table pendingbot.audit_log
  drop column if exists audio_seconds_billed;

-- 4. drop the bots.voice_call_provider column. The check constraint
-- (added in the same earlier migration via a DO $$ ... $$ block) is
-- dropped along with the column.
alter table pendingbot.bots
  drop column if exists voice_call_provider;
