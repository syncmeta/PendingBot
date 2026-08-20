-- edge 侧整数影子账：记录每笔 credit 进出(topup/refund/admin/redemption)。
-- Polar 是余额事实源;本表是 reconciliation 基准 + 供应商锁定/冻结的迁移底稿。
-- 见 docs/superpowers/specs/2026-06-01-billing-engine-design.md。
create table if not exists pendingbot.pnc_ledger (
  id               uuid primary key default gen_random_uuid(),
  subject_id       uuid not null references pendingbot.subjects(id) on delete cascade,
  kind             text not null check (kind in ('topup','refund','admin','redemption')),
  source           text not null,                  -- polar_checkout / iap_ios / admin / redemption ...
  external_ref     text not null,                  -- 上游交易 id(order.id / RC transaction_id),幂等键
  delta_pnc_micros bigint not null,                -- 正=加额度;负=减额度(退款)
  markup_snapshot  numeric,                        -- 卖包当时 markup(仅 topup)
  gross_paid_usd_cents int,
  net_revenue_usd_cents int,
  polar_synced     boolean not null default false, -- 是否已成功推给 Polar
  raw              jsonb,
  created_at       timestamptz not null default now(),
  unique (source, external_ref)                    -- 幂等:同一交易只入账一次
);
create index if not exists pnc_ledger_subject_idx on pendingbot.pnc_ledger (subject_id, created_at desc);
