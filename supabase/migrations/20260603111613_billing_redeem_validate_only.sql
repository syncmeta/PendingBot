-- 兑换码改走 Polar:billing_redeem 退化为"只校验 + 标记已用",不再写孤儿
-- topups 表 / billing_credit 旧钱包。实际入账由 edge 侧 recordCreditIn → Polar
-- grantCredits 完成(见 apps/edge/src/lib/billing-grant.ts:creditRedemptionToPolar)。
--
-- 返回 {credits(PND 原值), code_id} 供 edge 换算 PNC micros(×10_000)+ 幂等键。
-- 原子性保留:FOR UPDATE 锁 + 同一事务标记 used,防并发双兑换。
-- redemption_codes 表留用(只是入账通道换成 Polar)。

CREATE OR REPLACE FUNCTION pendingbot.billing_redeem(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pendingbot', 'public'
AS $function$
DECLARE
  v_user_id  uuid := auth.uid();
  v_code_row record;
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

  -- 不再写 topups / billing_credit(已退役);入账由 edge 走 Polar。
  RETURN jsonb_build_object(
    'credits', v_code_row.credits,   -- PND 原值;edge 换 PNC micros
    'code_id', v_code_row.id
  );
END $function$;
