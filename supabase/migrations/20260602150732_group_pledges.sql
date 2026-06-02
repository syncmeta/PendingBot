-- 认缴(pledge):成员给群授权的扣款上限(钱不动,留个人钱包)。
-- 群里有效份额 = min(pledge, 个人余额);消费时按占比当场从个人钱包直扣。
-- 见 docs/superpowers/specs/2026-06-02-group-billing-pledge-model-design.md
--     docs/superpowers/plans/2026-06-02-group-billing-pledge-model.md Task 1。

set search_path = pendingbot, public;

create table if not exists pendingbot.group_pledges (
  subject_id        uuid not null references pendingbot.subjects(id) on delete cascade,
  user_id           uuid not null references pendingbot.users(id) on delete cascade,
  pledge_pnc_micros bigint not null check (pledge_pnc_micros >= 0),
  status            text not null default 'active' check (status in ('active','revoked')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (subject_id, user_id)
);

alter table pendingbot.group_pledges enable row level security;

-- 本人读写自己的认缴
create policy group_pledges_self on pendingbot.group_pledges
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 群 owner/admin 读全群(_grp_caller_role(subject_id, caller) 返回角色)
create policy group_pledges_admin_read on pendingbot.group_pledges
  for select using (pendingbot._grp_caller_role(subject_id, auth.uid()) in ('owner','admin'));

-- 部分取出:从实缴池退回 amount 给成员,按比例缩其 active contributions,share_index 不变。
-- 返回实际退出额(夹到 share_now 与池子)。
create or replace function pendingbot.apply_partial_withdraw(
  p_subject_id uuid, p_user_id uuid, p_amount_micros bigint
) returns bigint language plpgsql security definer as $$
declare v_total bigint; v_idx numeric(40,20); v_sharenow bigint; v_factor numeric; v_refund bigint;
begin
  if p_amount_micros is null or p_amount_micros <= 0 then return 0; end if;
  select total_remaining_pnc_micros, share_index into v_total, v_idx
    from pendingbot.group_pools where subject_id = p_subject_id for update;
  if not found then return 0; end if;
  select coalesce(sum(floor(contributed_pnc_micros * (v_idx / share_index_at_join))), 0)
    into v_sharenow
    from pendingbot.group_contributions
    where subject_id = p_subject_id and contributor_user_id = p_user_id and status = 'active';
  v_refund := least(p_amount_micros, v_sharenow, v_total);
  if v_refund <= 0 then return 0; end if;
  v_factor := (v_sharenow - v_refund)::numeric / v_sharenow;   -- 按比例缩 contributed(idx 不变 = 份额等比缩)
  update pendingbot.group_contributions
    set contributed_pnc_micros = floor(contributed_pnc_micros * v_factor)
    where subject_id = p_subject_id and contributor_user_id = p_user_id and status = 'active';
  update pendingbot.group_pools
    set total_remaining_pnc_micros = greatest(0, v_total - v_refund), updated_at = now()
    where subject_id = p_subject_id;
  return v_refund;
end $$;

revoke all on function pendingbot.apply_partial_withdraw(uuid, uuid, bigint) from public, anon, authenticated;
