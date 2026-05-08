-- Lower the signup bonus from 5000 → 3500. Tied to the 1000 → 2700 PND
-- ratio change in apps/edge/src/lib/billing.ts: the old 5000 was ~$2 of
-- LLM headroom (1000 PND/$ × 2.5× markup); 3500 at the new 2700 PND/$
-- rate is ~$0.52 of provider headroom — enough for 50–100 cheap-model
-- turns, more in line with "tasting menu" rather than "free month".
--
-- Stored value is a jsonb literal (see 0033_billing.sql:126); RPC
-- billing_signup_bonus() reads it on each new-account grant. No backfill
-- — pre-existing accounts already received their 5000 from the prior
-- value; this only affects accounts created after deploy.
UPDATE pendingbot.billing_config
SET value = '3500'::jsonb,
    updated_at = now()
WHERE key = 'signup_bonus_credits';
