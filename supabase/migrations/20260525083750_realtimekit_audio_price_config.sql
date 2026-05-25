-- Expose the Cloudflare RealtimeKit audio-only participant-minute price as
-- a billing knob. The Worker falls back to the same value if this row is
-- absent, but keeping it in billing_config makes GA price changes explicit.

BEGIN;

SET search_path TO pendingbot, public;

INSERT INTO pendingbot.billing_config (key, value)
VALUES (
  'cloudflare_realtimekit_audio_participant_usd_per_minute',
  to_jsonb(0.0005::numeric)
)
ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE pendingbot.billing_config IS
  'Admin-tunable billing knobs: min_balance_threshold (PND pre-call gate), signup_bonus_credits, markup (USD->PND multiplier), default_attachment_quota_bytes, and cloudflare_realtimekit_audio_participant_usd_per_minute.';

COMMIT;
