-- 废除 billing-v2/v1 退役后的纯孤儿(A 段)。清单 + 分层见 docs/tech-debt.md
-- 「billing-v2/v1 退役后的 DB 孤儿全清单」+ docs/superpowers/specs/2026-06-03-
-- polar-grant-redeem-orphan-purge.md。
--
-- 前置(硬约束):本迁移**必须在新 edge 代码部署到生产之后**才 apply ——
--   1) 计费 gate/扣费早已走 WalletDO(计费 P2),不读这些表/RPC;
--   2) 兑换入账已改走 Polar(迁移 20260603111613 把 billing_redeem 退化为只校验,
--      不再调 billing_credit / 写 topups);
--   3) 送(signup)改走 Polar grant,旧 on_user_billing_signup 触发器在此删除。
-- 若提前 apply 而生产仍跑旧代码,旧路径会 500。
--
-- 不在本迁移(B 段,代码仍碰,留给 #226 解耦后再删):
--   subject_wallets(me.ts getSubjectBalance 仍读)、group_member_billing(invite 流仍写)。
-- redemption_codes 留用(兑换码存储;入账已改走 Polar)。

-- 1) 送(signup)旧赠送:触发器 + 触发函数 + 赠送函数(写孤儿 packs,新模型不读)。
DROP TRIGGER IF EXISTS on_user_billing_signup ON pendingbot.users;
DROP FUNCTION IF EXISTS pendingbot.billing_signup_bonus_trigger() CASCADE;
DROP FUNCTION IF EXISTS pendingbot.billing_signup_bonus(uuid) CASCADE;

-- 2) 孤儿 RPC(无活代码调用;旧钱包/兑换/充值/admin 调整/群计费设置)。
DROP FUNCTION IF EXISTS pendingbot.billing_admin_grant CASCADE;
DROP FUNCTION IF EXISTS pendingbot.billing_credit CASCADE;
DROP FUNCTION IF EXISTS pendingbot.billing_debit CASCADE;
DROP FUNCTION IF EXISTS pendingbot.billing_debit_subject CASCADE;
DROP FUNCTION IF EXISTS pendingbot.billing_issue_codes CASCADE;
DROP FUNCTION IF EXISTS pendingbot.billing_v2_admin_adjust CASCADE;
DROP FUNCTION IF EXISTS pendingbot.group_set_billing CASCADE;
DROP FUNCTION IF EXISTS pendingbot.grp_topup_wallet CASCADE;

-- 3) 孤儿表(新计费只读 pnc_ledger/group_pools/group_contributions/group_pledges)。
DROP TABLE IF EXISTS pendingbot.billing_ledger CASCADE;
DROP TABLE IF EXISTS pendingbot.group_billing_config CASCADE;
DROP TABLE IF EXISTS pendingbot.group_billing_custom_shares CASCADE;
DROP TABLE IF EXISTS pendingbot.ledger_entries CASCADE;
DROP TABLE IF EXISTS pendingbot.packs CASCADE;
DROP TABLE IF EXISTS pendingbot.topups CASCADE;
DROP TABLE IF EXISTS pendingbot.refund_events CASCADE;
