-- Billing v2 admin adjustment RPC (see docs/billing-v2-design.md §12).
--
-- The board (apps/board) talks to Postgres directly via the service-role
-- key; it can't import the edge worker's settleUsage/issuePack TS. So the
-- admin "grant / claw back PNC" operation lives here as a SECURITY DEFINER
-- RPC that does the pack + ledger writes atomically.
--
--   billing_v2_admin_adjust(p_owner_user_id, p_delta_pnc_micros, p_reason,
--                           p_actor_user_id)
--
-- delta > 0  → issue an admin_grant pack (never-expires; admin grants are a
--              gift, not a timed sale) + 'adjustment' credit ledger entry.
-- delta < 0  → claw back: FIFO-debit active packs down to 0 (no overdraft —
--              admin claw-back can't push a user negative) + per-pack
--              'adjustment' debit ledger entries.
--
-- Returns the owner's new total active balance (pnc_micros).
--
-- service_role only — the board's supabaseAdmin() client. NOT granted to
-- authenticated; a leaked anon key can't mint PNC.

BEGIN;

CREATE OR REPLACE FUNCTION pendingbot.billing_v2_admin_adjust(
  p_owner_user_id uuid,
  p_delta_pnc_micros bigint,
  p_reason text,
  p_actor_user_id uuid
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_pack_id uuid;
  v_new_balance bigint;
  v_still_owed bigint;
  v_debit bigint;
  v_rec record;
  v_meta jsonb;
BEGIN
  IF p_delta_pnc_micros = 0 THEN
    RAISE EXCEPTION 'delta must be non-zero' USING ERRCODE = 'P0001';
  END IF;

  v_meta := jsonb_build_object(
    'admin_user_id', p_actor_user_id,
    'reason', coalesce(p_reason, '')
  );

  IF p_delta_pnc_micros > 0 THEN
    -- Grant: one admin_grant pack, never expires.
    INSERT INTO pendingbot.packs (
      owner_user_id, initial_pnc_micros, remaining_pnc_micros,
      expires_at, status, sales_channel, metadata
    ) VALUES (
      p_owner_user_id, p_delta_pnc_micros, p_delta_pnc_micros,
      NULL, 'active', 'admin_grant', v_meta
    )
    RETURNING id INTO v_pack_id;

    SELECT coalesce(sum(remaining_pnc_micros), 0) INTO v_new_balance
      FROM pendingbot.packs
      WHERE owner_user_id = p_owner_user_id AND status = 'active';

    INSERT INTO pendingbot.ledger_entries (
      owner_user_id, pack_id, entry_type,
      delta_pnc_micros, balance_after_pnc_micros, metadata
    ) VALUES (
      p_owner_user_id, v_pack_id, 'adjustment',
      p_delta_pnc_micros, v_new_balance, v_meta
    );

    RETURN v_new_balance;
  END IF;

  -- Claw back (delta < 0): FIFO-debit active packs down to zero.
  v_still_owed := -p_delta_pnc_micros;  -- positive amount to remove

  FOR v_rec IN
    SELECT id, remaining_pnc_micros
      FROM pendingbot.packs
      WHERE owner_user_id = p_owner_user_id AND status = 'active'
      ORDER BY expires_at ASC NULLS LAST, created_at ASC
      FOR UPDATE
  LOOP
    EXIT WHEN v_still_owed <= 0;
    v_debit := least(v_rec.remaining_pnc_micros, v_still_owed);
    IF v_debit <= 0 THEN CONTINUE; END IF;

    UPDATE pendingbot.packs
      SET remaining_pnc_micros = remaining_pnc_micros - v_debit,
          status = CASE WHEN remaining_pnc_micros - v_debit = 0
                        THEN 'exhausted' ELSE 'active' END
      WHERE id = v_rec.id;

    v_still_owed := v_still_owed - v_debit;

    SELECT coalesce(sum(remaining_pnc_micros), 0) INTO v_new_balance
      FROM pendingbot.packs
      WHERE owner_user_id = p_owner_user_id AND status = 'active';

    INSERT INTO pendingbot.ledger_entries (
      owner_user_id, pack_id, entry_type,
      delta_pnc_micros, balance_after_pnc_micros, metadata
    ) VALUES (
      p_owner_user_id, v_rec.id, 'adjustment',
      -v_debit, v_new_balance, v_meta
    );
  END LOOP;

  -- Final balance (covers the "nothing to claw back" path where the loop
  -- never ran).
  SELECT coalesce(sum(remaining_pnc_micros), 0) INTO v_new_balance
    FROM pendingbot.packs
    WHERE owner_user_id = p_owner_user_id AND status = 'active';

  RETURN v_new_balance;
END;
$$;

REVOKE ALL ON FUNCTION pendingbot.billing_v2_admin_adjust(uuid, bigint, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION pendingbot.billing_v2_admin_adjust(uuid, bigint, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_v2_admin_adjust(uuid, bigint, text, uuid) TO service_role;

COMMENT ON FUNCTION pendingbot.billing_v2_admin_adjust(uuid, bigint, text, uuid) IS
  'Billing v2 admin grant/claw-back. delta>0 issues a never-expiring admin_grant pack; delta<0 FIFO-debits active packs (floored at 0). Writes adjustment ledger entries. service_role only — board admin path (docs/billing-v2-design.md §12).';

COMMIT;
