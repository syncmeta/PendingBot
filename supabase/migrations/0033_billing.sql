-- 0033_billing.sql — minimal credit-based billing layer.
--
-- Architecture (LiteLLM × One-API hybrid, sized for v1 single-env):
--
--   * users.balance_credits           — ground-truth balance (integer
--     credits). Updated atomically only by SECURITY DEFINER RPCs;
--     authenticated role has UPDATE revoked at column level so a leaked
--     anon key can't tamper.
--
--   * audit_log.cost_credits          — per-LLM-call debit. The existing
--     audit_log already records cost_usd and tokens; we add the
--     credit-denominated charge alongside so audit_log itself doubles
--     as the "consume" side of the ledger (no double-write).
--
--   * billing_ledger                  — append-only log of NON-LLM
--     movements: topups, grants, redemptions, refunds, manual adjusts.
--     LLM consumes are NOT mirrored here — query audit_log directly.
--
--   * topups                          — payment / acquisition orders.
--     UNIQUE (channel, channel_txn_id) prevents replay (Apple IAP
--     transactionId, Stripe pi_*, redemption code id, etc).
--
--   * redemption_codes                — One-API style single-use codes.
--     Admin-issued; users redeem via billing_redeem RPC.
--
--   * billing_config                  — admin-tunable knobs
--     (signup_bonus_credits, min_balance_threshold). Read by RPCs.
--
-- Worker computes cost_credits = ceil(cost_usd × usd_to_credits × markup)
-- using compile-time constants (BILLING_USD_TO_CREDITS=1000, MARKUP=2.5);
-- those are not in billing_config yet because they shouldn't change without
-- a deploy round. signup_bonus_credits and min_balance_threshold *do* live
-- in billing_config so admin can tune live without a Worker redeploy.
--
-- Pre-call balance gate: Worker checks users.balance_credits >=
-- min_balance_threshold before issuing an LLM call. Post-call debit may
-- briefly drive balance negative under bursts; the next pre-call gate
-- blocks further calls. We do NOT do mid-stream holds (KISS).
--
-- New-user flow: AFTER INSERT trigger on pendingbot.users calls
-- billing_signup_bonus, which is idempotent (skips if a signup_bonus
-- topup already exists for that user). Backfills existing users at the
-- bottom of this migration.

BEGIN;

-- ============================================================
-- 1. users — balance fields
-- ============================================================

ALTER TABLE pendingbot.users
  ADD COLUMN IF NOT EXISTS balance_credits        bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS lifetime_topup_credits bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS lifetime_spent_credits bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS balance_updated_at     timestamptz;

-- Lock down balance fields against direct UPDATE by authenticated role.
-- The existing users_self_update policy lets users update their own row,
-- but we revoke UPDATE on the billing columns at GRANT level so even
-- with policy permission the column write is rejected.
REVOKE UPDATE (balance_credits, lifetime_topup_credits, lifetime_spent_credits, balance_updated_at)
  ON TABLE pendingbot.users FROM authenticated;

-- ============================================================
-- 2. audit_log — credit denomination + billing status
-- ============================================================

ALTER TABLE pendingbot.audit_log
  ADD COLUMN IF NOT EXISTS cost_credits   bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS billing_status text   NOT NULL DEFAULT 'pending';

-- Constrain billing_status (separate ALTER so re-runs stay idempotent —
-- ADD COLUMN IF NOT EXISTS skips, but a second CHECK ADD is harmless
-- only if not already present; wrap in DO block).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'pendingbot.audit_log'::regclass
       AND conname = 'audit_log_billing_status_check'
  ) THEN
    ALTER TABLE pendingbot.audit_log
      ADD CONSTRAINT audit_log_billing_status_check
      CHECK (billing_status IN ('pending','billed','unbilled','free','skipped'));
  END IF;
END $$;

-- Hot path for "show me my recent billable LLM activity".
CREATE INDEX IF NOT EXISTS idx_audit_user_billed
  ON pendingbot.audit_log(user_id, created_at DESC)
  WHERE billing_status IN ('billed','unbilled');

-- audit_log RLS is enabled but had no policies (deny-all to authenticated;
-- service_role bypasses). Add a self-read policy so users can fetch their
-- own billing history without going through Worker.
DROP POLICY IF EXISTS audit_log_self_read ON pendingbot.audit_log;
CREATE POLICY audit_log_self_read ON pendingbot.audit_log
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- ============================================================
-- 3. billing_config
-- ============================================================

CREATE TABLE IF NOT EXISTS pendingbot.billing_config (
  key        text  PRIMARY KEY,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE pendingbot.billing_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS billing_config_read ON pendingbot.billing_config;
CREATE POLICY billing_config_read ON pendingbot.billing_config
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS billing_config_admin_write ON pendingbot.billing_config;
CREATE POLICY billing_config_admin_write ON pendingbot.billing_config
  FOR ALL TO authenticated
  USING ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()))
  WITH CHECK ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.billing_config TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.billing_config TO service_role;

INSERT INTO pendingbot.billing_config(key, value) VALUES
  ('signup_bonus_credits',  '5000'::jsonb),
  ('min_balance_threshold', '500'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 4. topups
-- ============================================================

CREATE TABLE IF NOT EXISTS pendingbot.topups (
  id                uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  user_id           uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  channel           text NOT NULL CHECK (channel IN
    ('apple_iap','stripe','redemption','admin_grant','signup_bonus','adjust')),
  channel_txn_id    text,
  paid_amount_minor int,
  paid_currency     text,
  credits_granted   bigint NOT NULL,
  status            text   NOT NULL DEFAULT 'verified'
                    CHECK (status IN ('pending','verified','failed','refunded')),
  raw_receipt       jsonb,
  is_sandbox        boolean NOT NULL DEFAULT false,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  verified_at       timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS topups_channel_txn_uniq
  ON pendingbot.topups(channel, channel_txn_id)
  WHERE channel_txn_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS topups_user_created
  ON pendingbot.topups(user_id, created_at DESC);

ALTER TABLE pendingbot.topups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS topups_self_read ON pendingbot.topups;
CREATE POLICY topups_self_read ON pendingbot.topups
  FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS topups_admin_all ON pendingbot.topups;
CREATE POLICY topups_admin_all ON pendingbot.topups
  FOR ALL TO authenticated
  USING ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()))
  WITH CHECK ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()));

-- All inserts go through SECURITY DEFINER RPCs; no direct insert policy
-- for non-admins.

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.topups TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.topups TO service_role;

-- ============================================================
-- 5. redemption_codes
-- ============================================================

CREATE TABLE IF NOT EXISTS pendingbot.redemption_codes (
  id           uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  code         text NOT NULL UNIQUE,
  credits      bigint NOT NULL CHECK (credits > 0),
  status       text   NOT NULL DEFAULT 'enabled'
               CHECK (status IN ('enabled','disabled','used')),
  created_by   uuid REFERENCES auth.users(id),
  redeemed_by  uuid REFERENCES auth.users(id),
  batch_label  text,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  redeemed_at  timestamptz
);

CREATE INDEX IF NOT EXISTS redemption_codes_status
  ON pendingbot.redemption_codes(status);

ALTER TABLE pendingbot.redemption_codes ENABLE ROW LEVEL SECURITY;

-- Codes are admin-only artifacts. Regular users never SELECT — they
-- redeem via the billing_redeem RPC, which is SECURITY DEFINER and
-- bypasses RLS.
DROP POLICY IF EXISTS redemption_codes_admin ON pendingbot.redemption_codes;
CREATE POLICY redemption_codes_admin ON pendingbot.redemption_codes
  FOR ALL TO authenticated
  USING ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()))
  WITH CHECK ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.redemption_codes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.redemption_codes TO service_role;

-- ============================================================
-- 6. billing_ledger
-- ============================================================

CREATE TABLE IF NOT EXISTS pendingbot.billing_ledger (
  id             uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  entry_type     text NOT NULL CHECK (entry_type IN
    ('topup','grant','redemption','refund','adjust','signup_bonus')),
  delta_credits  bigint NOT NULL,
  topup_id       uuid REFERENCES pendingbot.topups(id),
  redemption_id  uuid REFERENCES pendingbot.redemption_codes(id),
  actor_user_id  uuid REFERENCES auth.users(id),
  reason         text,
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS billing_ledger_user_created
  ON pendingbot.billing_ledger(user_id, created_at DESC);

ALTER TABLE pendingbot.billing_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS billing_ledger_self_read ON pendingbot.billing_ledger;
CREATE POLICY billing_ledger_self_read ON pendingbot.billing_ledger
  FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS billing_ledger_admin_all ON pendingbot.billing_ledger;
CREATE POLICY billing_ledger_admin_all ON pendingbot.billing_ledger
  FOR ALL TO authenticated
  USING ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()))
  WITH CHECK ((SELECT is_admin FROM pendingbot.users WHERE id = auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.billing_ledger TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.billing_ledger TO service_role;

-- ============================================================
-- 7. RPCs
-- ============================================================

-- Read an integer scalar from billing_config. NULL when missing.
CREATE OR REPLACE FUNCTION pendingbot.billing_config_int(p_key text)
RETURNS bigint
LANGUAGE sql
STABLE SECURITY DEFINER SET search_path = pendingbot, public
AS $$
  SELECT (value)::text::bigint
    FROM pendingbot.billing_config
   WHERE key = p_key
$$;

-- Debit credits for an LLM call. Worker calls this AFTER inserting the
-- audit_log row. Updates audit_log.billing_status. Always succeeds —
-- balance can briefly go negative under burst; the next pre-call gate
-- blocks further requests.
CREATE OR REPLACE FUNCTION pendingbot.billing_debit(
  p_user_id      uuid,
  p_audit_log_id uuid,
  p_credits      bigint
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_new_balance bigint;
BEGIN
  IF p_credits <= 0 THEN
    UPDATE pendingbot.audit_log
       SET billing_status = 'skipped'
     WHERE id = p_audit_log_id;
    SELECT balance_credits INTO v_new_balance
      FROM pendingbot.users WHERE id = p_user_id;
    RETURN v_new_balance;
  END IF;

  UPDATE pendingbot.users
     SET balance_credits        = balance_credits - p_credits,
         lifetime_spent_credits = lifetime_spent_credits + p_credits,
         balance_updated_at     = now()
   WHERE id = p_user_id
  RETURNING balance_credits INTO v_new_balance;

  IF NOT FOUND THEN
    UPDATE pendingbot.audit_log
       SET billing_status = 'unbilled'
     WHERE id = p_audit_log_id;
    RETURN NULL;
  END IF;

  UPDATE pendingbot.audit_log
     SET billing_status = CASE WHEN v_new_balance < 0 THEN 'unbilled' ELSE 'billed' END
   WHERE id = p_audit_log_id;

  RETURN v_new_balance;
END $$;

-- Credit a user. Used by signup bonus, redemption, admin grant, IAP
-- topup. Caller is responsible for inserting the topup row first when
-- there is a payment artifact. Returns new balance.
CREATE OR REPLACE FUNCTION pendingbot.billing_credit(
  p_user_id        uuid,
  p_credits        bigint,
  p_kind           text,
  p_topup_id       uuid     DEFAULT NULL,
  p_redemption_id  uuid     DEFAULT NULL,
  p_actor_user_id  uuid     DEFAULT NULL,
  p_reason         text     DEFAULT NULL,
  p_metadata       jsonb    DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_new_balance bigint;
BEGIN
  IF p_credits = 0 THEN
    SELECT balance_credits INTO v_new_balance
      FROM pendingbot.users WHERE id = p_user_id;
    RETURN v_new_balance;
  END IF;

  UPDATE pendingbot.users
     SET balance_credits        = balance_credits + p_credits,
         lifetime_topup_credits = lifetime_topup_credits +
           CASE WHEN p_credits > 0 AND p_kind <> 'refund'
                THEN p_credits ELSE 0 END,
         balance_updated_at     = now()
   WHERE id = p_user_id
  RETURNING balance_credits INTO v_new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user % not found', p_user_id;
  END IF;

  INSERT INTO pendingbot.billing_ledger(
    user_id, entry_type, delta_credits,
    topup_id, redemption_id, actor_user_id, reason, metadata
  ) VALUES (
    p_user_id, p_kind, p_credits,
    p_topup_id, p_redemption_id, p_actor_user_id, p_reason, p_metadata
  );

  RETURN v_new_balance;
END $$;

-- Redeem a code as the calling user. Atomic: locks code row, marks it
-- 'used', inserts topup + ledger, bumps balance. Custom errors carry
-- ERRCODE so the worker can map to user-friendly messages.
--   42501 = not authenticated
--   P0002 = code not found
--   P0001 = code already used / disabled
CREATE OR REPLACE FUNCTION pendingbot.billing_redeem(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_code_row    record;
  v_topup_id    uuid;
  v_new_balance bigint;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_code_row
    FROM pendingbot.redemption_codes
   WHERE code = p_code
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'redemption code not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_code_row.status <> 'enabled' THEN
    RAISE EXCEPTION 'redemption code is % (must be enabled)', v_code_row.status
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE pendingbot.redemption_codes
     SET status      = 'used',
         redeemed_by = v_user_id,
         redeemed_at = now()
   WHERE id = v_code_row.id;

  INSERT INTO pendingbot.topups(
    user_id, channel, channel_txn_id, credits_granted, status, verified_at
  ) VALUES (
    v_user_id, 'redemption', v_code_row.id::text,
    v_code_row.credits, 'verified', now()
  )
  RETURNING id INTO v_topup_id;

  v_new_balance := pendingbot.billing_credit(
    v_user_id, v_code_row.credits, 'redemption',
    v_topup_id, v_code_row.id, NULL,
    'redeemed code ' || left(p_code, 4) || '…',
    jsonb_build_object('code_id', v_code_row.id)
  );

  RETURN jsonb_build_object(
    'credits',     v_code_row.credits,
    'new_balance', v_new_balance
  );
END $$;

GRANT EXECUTE ON FUNCTION pendingbot.billing_redeem(text) TO authenticated;

-- Signup bonus — idempotent. Skips if user already has any topup of
-- channel='signup_bonus'. Reads amount from billing_config.
CREATE OR REPLACE FUNCTION pendingbot.billing_signup_bonus(p_user_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_credits  bigint;
  v_existing uuid;
  v_topup_id uuid;
BEGIN
  v_credits := pendingbot.billing_config_int('signup_bonus_credits');
  IF v_credits IS NULL OR v_credits <= 0 THEN
    RETURN 0;
  END IF;

  SELECT id INTO v_existing
    FROM pendingbot.topups
   WHERE user_id = p_user_id AND channel = 'signup_bonus'
   LIMIT 1;
  IF FOUND THEN
    RETURN v_credits;
  END IF;

  INSERT INTO pendingbot.topups(
    user_id, channel, credits_granted, status, verified_at, notes
  ) VALUES (
    p_user_id, 'signup_bonus', v_credits, 'verified', now(),
    'auto signup bonus'
  )
  RETURNING id INTO v_topup_id;

  PERFORM pendingbot.billing_credit(
    p_user_id, v_credits, 'signup_bonus',
    v_topup_id, NULL, NULL,
    'signup bonus', '{}'::jsonb
  );

  RETURN v_credits;
END $$;

-- ============================================================
-- 8. Signup-bonus trigger (decoupled from bootstrap_user_id)
-- ============================================================

CREATE OR REPLACE FUNCTION pendingbot.billing_signup_bonus_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
BEGIN
  PERFORM pendingbot.billing_signup_bonus(NEW.id);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS on_user_billing_signup ON pendingbot.users;
CREATE TRIGGER on_user_billing_signup
  AFTER INSERT ON pendingbot.users
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot.billing_signup_bonus_trigger();

-- ============================================================
-- 9. Backfill existing users with the signup bonus
-- ============================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT u.id
      FROM pendingbot.users u
     WHERE NOT EXISTS (
       SELECT 1 FROM pendingbot.topups t
        WHERE t.user_id = u.id
          AND t.channel = 'signup_bonus'
     )
  LOOP
    PERFORM pendingbot.billing_signup_bonus(r.id);
  END LOOP;
END $$;

COMMIT;
