-- 0034_billing_admin_rpcs.sql — admin-facing helpers built on the
-- ledger primitives from 0033.
--
-- Two RPCs, both check is_admin via auth.uid() inside (no plain
-- service-role-only escape hatches; the same calls work from admin
-- panel running as an authenticated admin user, OR from worker code
-- via service role bypassing RLS):
--
--   billing_issue_codes(p_count, p_credits, p_label) → text[]
--     Bulk-creates redemption codes. Codes are 16-char hex from
--     gen_random_bytes(8), conflict-retried up to a few times if the
--     unique index trips (vanishingly rare at this scale).
--
--   billing_admin_grant(p_user_id, p_credits, p_reason) → bigint
--     Grant credits directly to a user (compensation, beta access,
--     bug bounty, etc). Records as a topup with channel='admin_grant'
--     and a ledger entry attributing the actor.

BEGIN;

-- ============================================================
-- billing_issue_codes
-- ============================================================

CREATE OR REPLACE FUNCTION pendingbot.billing_issue_codes(
  p_count   int,
  p_credits bigint,
  p_label   text DEFAULT NULL
) RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_actor   uuid := auth.uid();
  v_is_admin boolean;
  v_codes   text[] := ARRAY[]::text[];
  v_code    text;
  v_attempt int;
  v_inserted_id uuid;
  v_i       int;
BEGIN
  -- Allow either an admin in pendingbot.users OR the service role
  -- (auth.uid() is NULL when service_role calls). Worker bulk-issuance
  -- via service role legitimately doesn't have a user.
  IF v_actor IS NULL THEN
    -- service role caller; no further check
    NULL;
  ELSE
    SELECT is_admin INTO v_is_admin
      FROM pendingbot.users WHERE id = v_actor;
    IF NOT COALESCE(v_is_admin, false) THEN
      RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_count IS NULL OR p_count <= 0 OR p_count > 1000 THEN
    RAISE EXCEPTION 'p_count must be 1..1000';
  END IF;
  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'p_credits must be > 0';
  END IF;

  FOR v_i IN 1 .. p_count LOOP
    -- Try up to 5 times to dodge the (vanishingly unlikely) UNIQUE collision.
    v_attempt := 0;
    LOOP
      v_attempt := v_attempt + 1;
      v_code := encode(extensions.gen_random_bytes(8), 'hex');
      BEGIN
        INSERT INTO pendingbot.redemption_codes(code, credits, status, created_by, batch_label)
        VALUES (v_code, p_credits, 'enabled', v_actor, p_label)
        RETURNING id INTO v_inserted_id;
        v_codes := array_append(v_codes, v_code);
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        IF v_attempt >= 5 THEN
          RAISE;
        END IF;
      END;
    END LOOP;
  END LOOP;

  RETURN v_codes;
END $$;

GRANT EXECUTE ON FUNCTION pendingbot.billing_issue_codes(int, bigint, text)
  TO authenticated;

-- ============================================================
-- billing_admin_grant
-- ============================================================

CREATE OR REPLACE FUNCTION pendingbot.billing_admin_grant(
  p_user_id uuid,
  p_credits bigint,
  p_reason  text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_actor    uuid := auth.uid();
  v_is_admin boolean;
  v_topup_id uuid;
  v_balance  bigint;
BEGIN
  IF v_actor IS NULL THEN
    -- service role caller; allowed
    NULL;
  ELSE
    SELECT is_admin INTO v_is_admin
      FROM pendingbot.users WHERE id = v_actor;
    IF NOT COALESCE(v_is_admin, false) THEN
      RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_credits = 0 THEN
    RAISE EXCEPTION 'p_credits must be non-zero';
  END IF;

  -- Insert topup row first so the ledger entry can reference it.
  -- channel='admin_grant'; channel_txn_id is NULL because there's no
  -- external transaction (the unique index is partial WHERE
  -- channel_txn_id IS NOT NULL, so multiple admin grants don't clash).
  INSERT INTO pendingbot.topups(
    user_id, channel, credits_granted, status, verified_at, notes
  ) VALUES (
    p_user_id, 'admin_grant', p_credits, 'verified', now(), p_reason
  )
  RETURNING id INTO v_topup_id;

  v_balance := pendingbot.billing_credit(
    p_user_id, p_credits,
    CASE WHEN p_credits < 0 THEN 'adjust' ELSE 'grant' END,
    v_topup_id, NULL, v_actor, p_reason, '{}'::jsonb
  );

  RETURN v_balance;
END $$;

GRANT EXECUTE ON FUNCTION pendingbot.billing_admin_grant(uuid, bigint, text)
  TO authenticated;

COMMIT;
