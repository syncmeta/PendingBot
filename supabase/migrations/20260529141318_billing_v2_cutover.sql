-- Billing v2 cutover (see docs/billing-v2-design.md §14).
--
-- Pre-launch, single-env, single-dev. v1 was never validated and
-- under-recorded, so we do NOT keep it as a parallel source of truth —
-- v2 becomes authoritative here. This migration:
--
--   1. Migrates every positive v1 balance (users.balance_credits and
--      subject_wallets.balance_credits) into a never-expiring
--      v1_migration v2 pack, preserving USD-equivalent value.
--   2. Rewrites the signup-bonus path to mint a v2 pack instead of a v1
--      credit, so new users land directly in v2.
--
-- We do NOT drop the v1 tables (billing_ledger / topups /
-- redemption_codes / group_member_billing / users.balance_credits). They
-- go unused but stay as a cold backup for one cycle; a later cleanup
-- migration can drop them once v2 has run in production. billing_config
-- and web_tool_prices STAY — they're pricebooks/knobs v2 still reads, not
-- v1 ledger.
--
-- Conversion: v1 headline rate 2700 PND = 1 USD; v2 27 PNC = 1 USD.
--   1 PND  = 0.01 PNC = 10_000 micros
--   pnc_micros = balance_credits * 10_000
-- This preserves the user's USD-equivalent purchasing power exactly.

BEGIN;

-- ============================================================
-- 1. Migrate user balances → v1_migration packs
-- ============================================================
INSERT INTO pendingbot.packs (
  owner_user_id, initial_pnc_micros, remaining_pnc_micros,
  expires_at, status, sales_channel, metadata
)
SELECT
  u.id,
  u.balance_credits * 10000,
  u.balance_credits * 10000,
  NULL,                       -- migration packs never expire
  'active',
  'v1_migration',
  jsonb_build_object(
    'migrated_from', 'users.balance_credits',
    'v1_balance_credits', u.balance_credits
  )
FROM pendingbot.users u
WHERE u.balance_credits > 0
  -- idempotency: skip users who already have a migration pack
  AND NOT EXISTS (
    SELECT 1 FROM pendingbot.packs p
     WHERE p.owner_user_id = u.id
       AND p.sales_channel = 'v1_migration'
  );

-- Matching credit ledger entries for the user migration packs.
INSERT INTO pendingbot.ledger_entries (
  owner_user_id, pack_id, entry_type,
  delta_pnc_micros, balance_after_pnc_micros, metadata
)
SELECT
  p.owner_user_id, p.id, 'credit',
  p.initial_pnc_micros, p.initial_pnc_micros,
  jsonb_build_object('source', 'v1_migration')
FROM pendingbot.packs p
WHERE p.sales_channel = 'v1_migration'
  AND p.owner_user_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM pendingbot.ledger_entries l
     WHERE l.pack_id = p.id AND l.entry_type = 'credit'
  );

-- ============================================================
-- 2. Migrate subject wallet balances → v1_migration subject packs
-- ============================================================
INSERT INTO pendingbot.packs (
  owner_subject_id, initial_pnc_micros, remaining_pnc_micros,
  expires_at, status, sales_channel, metadata
)
SELECT
  w.subject_id,
  w.balance_credits * 10000,
  w.balance_credits * 10000,
  NULL,
  'active',
  'v1_migration',
  jsonb_build_object(
    'migrated_from', 'subject_wallets.balance_credits',
    'v1_balance_credits', w.balance_credits
  )
FROM pendingbot.subject_wallets w
WHERE w.balance_credits > 0
  AND NOT EXISTS (
    SELECT 1 FROM pendingbot.packs p
     WHERE p.owner_subject_id = w.subject_id
       AND p.sales_channel = 'v1_migration'
  );

-- Seed a group_pools row for each subject that got a migration pack, so
-- the share-index model has a starting balance to decay from.
INSERT INTO pendingbot.group_pools (subject_id, total_remaining_pnc_micros, share_index)
SELECT p.owner_subject_id, p.initial_pnc_micros, 1.0
FROM pendingbot.packs p
WHERE p.sales_channel = 'v1_migration'
  AND p.owner_subject_id IS NOT NULL
ON CONFLICT (subject_id) DO NOTHING;

INSERT INTO pendingbot.ledger_entries (
  owner_subject_id, pack_id, entry_type,
  delta_pnc_micros, balance_after_pnc_micros, metadata
)
SELECT
  p.owner_subject_id, p.id, 'credit',
  p.initial_pnc_micros, p.initial_pnc_micros,
  jsonb_build_object('source', 'v1_migration')
FROM pendingbot.packs p
WHERE p.sales_channel = 'v1_migration'
  AND p.owner_subject_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM pendingbot.ledger_entries l
     WHERE l.pack_id = p.id AND l.entry_type = 'credit'
  );

-- ============================================================
-- 3. Signup bonus → v2 pack
-- ============================================================
-- Rewrite billing_signup_bonus to mint a never-expiring v2 admin_grant
-- pack (metadata.reason = 'signup_bonus') instead of a v1 credit. The
-- trigger (on_user_billing_signup) keeps firing; only the body changes.
CREATE OR REPLACE FUNCTION pendingbot.billing_signup_bonus(p_user_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_credits   bigint;   -- read in v1 PND units from billing_config
  v_micros    bigint;
  v_pack_id   uuid;
  v_balance   bigint;
BEGIN
  v_credits := pendingbot.billing_config_int('signup_bonus_credits');
  IF v_credits IS NULL OR v_credits <= 0 THEN
    RETURN 0;
  END IF;
  v_micros := v_credits * 10000;  -- PND → PNC micros

  -- Idempotency: skip if a signup_bonus v2 pack already exists.
  IF EXISTS (
    SELECT 1 FROM pendingbot.packs p
     WHERE p.owner_user_id = p_user_id
       AND p.sales_channel = 'admin_grant'
       AND p.metadata->>'reason' = 'signup_bonus'
  ) THEN
    RETURN v_credits;
  END IF;

  INSERT INTO pendingbot.packs (
    owner_user_id, initial_pnc_micros, remaining_pnc_micros,
    expires_at, status, sales_channel, metadata
  ) VALUES (
    p_user_id, v_micros, v_micros, NULL, 'active', 'admin_grant',
    jsonb_build_object('reason', 'signup_bonus')
  )
  RETURNING id INTO v_pack_id;

  SELECT coalesce(sum(remaining_pnc_micros), 0) INTO v_balance
    FROM pendingbot.packs
    WHERE owner_user_id = p_user_id AND status = 'active';

  INSERT INTO pendingbot.ledger_entries (
    owner_user_id, pack_id, entry_type,
    delta_pnc_micros, balance_after_pnc_micros, metadata
  ) VALUES (
    p_user_id, v_pack_id, 'credit',
    v_micros, v_balance, jsonb_build_object('reason', 'signup_bonus')
  );

  RETURN v_credits;
END $$;

COMMENT ON FUNCTION pendingbot.billing_signup_bonus(uuid) IS
  'Billing v2: mints a never-expiring signup-bonus pack (admin_grant, metadata.reason=signup_bonus). Reads signup_bonus_credits (v1 PND units) from billing_config, converts to PNC micros (×10_000). Idempotent per user. Trigger on_user_billing_signup still fires it AFTER INSERT on users.';

COMMIT;
