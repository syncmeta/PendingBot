-- Clear stale group billing freezes after the underlying condition is gone.
--
-- `group_member_billing.overdrawn` is raised when a member cannot pay a
-- split (wallet balance too low) or when their per-group cap is exhausted.
-- Before this migration, topups and cap edits did not flip it back, so the
-- iOS "已达上限" state could stick even after the user had enough balance
-- and no active cap.

BEGIN;

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

  IF p_credits > 0 AND v_new_balance > 0 THEN
    UPDATE pendingbot.group_member_billing
       SET overdrawn = false
     WHERE user_id = p_user_id
       AND overdrawn = true
       AND (cap_credits IS NULL OR spent_credits < cap_credits);
  END IF;

  RETURN v_new_balance;
END $$;

CREATE OR REPLACE FUNCTION pendingbot.group_set_member_cap(
  p_conv_id uuid,
  p_cap_credits bigint
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  caller_id uuid := auth.uid();
  v_balance bigint := 0;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._assert_group_role(p_conv_id, array['owner','admin','member','observer']);

  if p_cap_credits is not null and p_cap_credits < 0 then
    raise exception 'cap_credits must be >= 0';
  end if;

  select balance_credits into v_balance
    from pendingbot.users
   where id = caller_id;

  update pendingbot.group_member_billing
     set cap_credits = p_cap_credits,
         overdrawn = case
           when overdrawn = true
            and v_balance > 0
            and (p_cap_credits is null or spent_credits < p_cap_credits)
             then false
           else overdrawn
         end
   where conversation_id = p_conv_id and user_id = caller_id;
end $$;

ALTER FUNCTION pendingbot.group_set_member_cap(uuid, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.group_set_member_cap(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.group_set_member_cap(uuid, bigint) TO authenticated;

COMMIT;
