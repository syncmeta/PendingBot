-- Voice call infrastructure.
--
-- Two providers supported per bot:
--   * OpenAI Realtime (WebRTC SDP exchange, billed per audio token)
--   * Doubao 端到端实时语音 (火山 SpeechEngineToB SDK, billed per audio second
--     on our side — actual upstream is token-based but the SDK doesn't expose
--     a per-turn usage event, so the client ticks every ~10s and we fold the
--     elapsed seconds into cost via audio_per_minute_price)
--
-- audit_log gets three new usage dims (audio_input_tokens / audio_output_tokens
-- / audio_seconds_billed); llm_model_aliases gets three matching price dims;
-- bots gets the enablement flag + provider picker; messages gets a generic
-- metadata jsonb so voice-call transcripts can be tagged source='voice_call'
-- and re-flow through maybeRefreshMemory into Honcho on next chat window slide.

-- 1. audit_log: audio token + seconds dims
alter table pendingbot.audit_log
  add column if not exists audio_input_tokens int not null default 0,
  add column if not exists audio_output_tokens int not null default 0,
  add column if not exists audio_seconds_billed numeric;

-- 2. llm_model_aliases: audio pricing (null = alias doesn't bill audio)
alter table pendingbot.llm_model_aliases
  add column if not exists audio_input_price numeric,
  add column if not exists audio_output_price numeric,
  add column if not exists audio_per_minute_price numeric;

-- 3. bots: voice-call gate + provider pick
alter table pendingbot.bots
  add column if not exists voice_call_enabled boolean not null default false,
  add column if not exists voice_call_provider text not null default 'openai';

-- Use a separate ALTER for the check constraint so re-running this migration
-- after a partial apply doesn't fail with "constraint already exists".
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bots_voice_call_provider_check'
      and conrelid = 'pendingbot.bots'::regclass
  ) then
    alter table pendingbot.bots
      add constraint bots_voice_call_provider_check
      check (voice_call_provider in ('openai', 'doubao'));
  end if;
end$$;

-- 4. messages: generic metadata column for source tagging
alter table pendingbot.messages
  add column if not exists metadata jsonb;

-- 5. seed providers (no-op if slugs already present)
insert into pendingbot.llm_providers
  (slug, display_name, base_url, auth_type, secret_ref, priority, enabled)
values
  ('openai', 'OpenAI Direct',
   'https://api.openai.com/v1',
   'bearer', 'OPENAI_API_KEY', 50, true),
  ('doubao', '豆包端到端实时语音',
   'wss://openspeech.bytedance.com',
   'bearer', 'DOUBAO_DIALOG_ACCESS_TOKEN', 55, true)
on conflict (slug) do nothing;

-- 6. seed realtime models
insert into pendingbot.llm_models
  (slug, display_name, family, capabilities, enabled)
values
  ('gpt-realtime', 'GPT Realtime (voice)', 'gpt',
   '{"voice": true, "transport": "openai_sdp"}'::jsonb, true),
  ('doubao-realtime', '豆包实时通话', 'doubao',
   '{"voice": true, "transport": "volc_dialog_ws"}'::jsonb, true)
on conflict (slug) do nothing;

-- 7. seed aliases
--   OpenAI: token-based pricing (USD per 1M)
insert into pendingbot.llm_model_aliases
  (model_id, provider_id, provider_model_id,
   input_price, output_price,
   audio_input_price, audio_output_price,
   weight, enabled)
select m.id, p.id, 'gpt-realtime-2025-08-28',
       5, 20,
       40, 80,
       100, true
from pendingbot.llm_models m
join pendingbot.llm_providers p on p.slug = 'openai'
where m.slug = 'gpt-realtime'
  and not exists (
    select 1 from pendingbot.llm_model_aliases a
    where a.model_id = m.id and a.provider_id = p.id
  );

--   Doubao: per-minute pricing (USD/min). Real upstream is token-based — the
--   placeholder 0.10 USD/min should be reset to a conservative figure derived
--   from (6.25 in tok/s + 25 out tok/s) × 牌价 once we validate against an
--   actual Volcengine bill. provider_model_id is the SDK ResourceId.
--
--   input_price / output_price are NOT NULL on llm_model_aliases (legacy
--   constraint from the text-only era), so we feed 0 to satisfy the schema
--   even though Doubao is billed off audio_per_minute_price alone.
insert into pendingbot.llm_model_aliases
  (model_id, provider_id, provider_model_id,
   input_price, output_price,
   audio_per_minute_price,
   weight, enabled)
select m.id, p.id, 'volc.speech.dialog',
       0, 0,
       0.10,
       100, true
from pendingbot.llm_models m
join pendingbot.llm_providers p on p.slug = 'doubao'
where m.slug = 'doubao-realtime'
  and not exists (
    select 1 from pendingbot.llm_model_aliases a
    where a.model_id = m.id and a.provider_id = p.id
  );
