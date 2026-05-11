-- 20260511042501_billing_markup_config.sql
--
-- Promotes the billing markup from a TS const (apps/edge/src/lib/billing.ts:19)
-- to a DB-tunable value in pendingbot.billing_config. Ops can now retune the
-- multiplier without a worker deploy.
--
-- We use the existing billing_config (key, value jsonb) table — the same one
-- that already holds min_balance_threshold. usdToPnd() in the worker becomes
-- a pure (cost, markup) function; recordAudit / group-router / group-bot-intro
-- await getMarkup(supa) once per call and pass it down.
--
-- The seed value matches the current TS default (2.5) so applying this
-- migration is a no-op for billing math until an admin actually edits it.
--
-- If the row already exists (e.g. someone seeded it manually via Studio),
-- the ON CONFLICT preserves their value.

BEGIN;

INSERT INTO pendingbot.billing_config (key, value)
VALUES ('markup', to_jsonb(2.5::numeric))
ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE pendingbot.billing_config IS
    'Singleton config rows keyed by string. Currently: '
    'min_balance_threshold (int, PND) — pre-call gate threshold; '
    'markup (numeric) — multiplier applied in usdToPnd over wholesale cost.';

COMMIT;
