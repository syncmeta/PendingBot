-- Align the OpenAI Realtime alias with the GA release dropped 2026-05-07
-- (https://openai.com/index/advancing-voice-intelligence-with-new-models-in-the-api/).
--
-- Three things change on the seed alias:
--
--   1. provider_model_id moves from the placeholder gpt-realtime-2025-08-28
--      to the new GA model id `gpt-realtime-2`. The earlier model id stays
--      callable on OpenAI's side but the new one is the recommended target.
--
--   2. Audio token prices update to the GA list:
--        audio_input_price   $40 → $32   /1M
--        audio_output_price  $80 → $64   /1M
--
--   3. cached_input_price drops to $0.40 /1M to capture the GA cached-audio
--      discount (cached audio bills at 80× off vs full input). Note: the
--      column is shared with the cached-text discount for text-only aliases;
--      since this alias only services voice (taskType='voice_call'), $0.40
--      is the audio-cached rate. computeCost folds usage.cacheReadTokens
--      through this single column.
--
-- Only UPDATEs — no schema change. Re-runnable.

update pendingbot.llm_model_aliases
   set provider_model_id  = 'gpt-realtime-2',
       audio_input_price  = 32,
       audio_output_price = 64,
       cached_input_price = 0.40,
       updated_at         = now()
 where provider_id = (select id from pendingbot.llm_providers where slug = 'openai')
   and model_id    = (select id from pendingbot.llm_models    where slug = 'gpt-realtime');
