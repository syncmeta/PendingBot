-- 群池原子操作(share-index 重挂到 Polar/WalletDO)。
-- 见 docs/superpowers/plans/2026-06-02-group-wallet-polar-rehome.md Task 2。
--
-- group_pools.total_remaining_pnc_micros 是公平性镜像(余额事实源在 Polar);
-- 这些函数只维护镜像 + share_index,并发安全(行级 FOR UPDATE / 单条 upsert)。

set search_path = pendingbot, public;

-- 群消费:total -= x; share_index *= (new/old),池空则 index 重置 1.0。
create or replace function pendingbot.apply_group_pool_spend(
  p_subject_id uuid, p_spend_micros bigint
) returns void language plpgsql security definer as $$
declare v_old bigint; v_idx numeric(40,20); v_new bigint;
begin
  if p_spend_micros is null or p_spend_micros <= 0 then return; end if;
  select total_remaining_pnc_micros, share_index into v_old, v_idx
    from pendingbot.group_pools where subject_id = p_subject_id for update;
  if not found then
    -- 群池尚未 bootstrap(成员还没注资就发生了消费):建一个 0 池。
    insert into pendingbot.group_pools(subject_id, total_remaining_pnc_micros, share_index)
      values (p_subject_id, 0, 1) on conflict (subject_id) do nothing;
    return;
  end if;
  v_new := v_old - p_spend_micros;
  update pendingbot.group_pools set
    total_remaining_pnc_micros = v_new,
    share_index = case
      when v_new <= 0 then 1
      when v_old <= 0 then v_idx
      else v_idx * v_new / v_old end,
    updated_at = now()
  where subject_id = p_subject_id;
end $$;

-- 注资:total += amount。返回 join 时(更新前)的 share_index 供 contribution 快照。
create or replace function pendingbot.apply_group_contribution(
  p_subject_id uuid, p_amount_micros bigint
) returns numeric language plpgsql security definer as $$
declare v_idx numeric(40,20);
begin
  if p_amount_micros is null or p_amount_micros <= 0 then return 1; end if;
  -- 先读(或建)拿到 join 时 index,再加余额。share_index 注资时不变。
  select share_index into v_idx
    from pendingbot.group_pools where subject_id = p_subject_id for update;
  if not found then
    insert into pendingbot.group_pools(subject_id, total_remaining_pnc_micros, share_index)
      values (p_subject_id, p_amount_micros, 1);
    return 1;
  end if;
  update pendingbot.group_pools set
    total_remaining_pnc_micros = total_remaining_pnc_micros + p_amount_micros,
    updated_at = now()
  where subject_id = p_subject_id;
  return coalesce(v_idx, 1);
end $$;

-- 退款:total -= refunded(share_index 不变),夹到 >=0。
create or replace function pendingbot.apply_group_refund(
  p_subject_id uuid, p_refund_micros bigint
) returns void language plpgsql security definer as $$
begin
  if p_refund_micros is null or p_refund_micros <= 0 then return; end if;
  update pendingbot.group_pools set
    total_remaining_pnc_micros = greatest(0, total_remaining_pnc_micros - p_refund_micros),
    updated_at = now()
  where subject_id = p_subject_id;
end $$;

-- 仅 service_role 调用(edge 内部 + DO),不开给客户端角色。
revoke all on function pendingbot.apply_group_pool_spend(uuid, bigint) from public, anon, authenticated;
revoke all on function pendingbot.apply_group_contribution(uuid, bigint) from public, anon, authenticated;
revoke all on function pendingbot.apply_group_refund(uuid, bigint) from public, anon, authenticated;
