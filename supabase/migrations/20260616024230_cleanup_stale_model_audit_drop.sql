-- 审计 Y7 + G16 — DB cleanup:drop 一批逐项确认 dead 的对象。
--
-- 每个 drop 都先全 supabase/migrations grep 过 view / 触发器 / FK / RLS / RPC /
-- 生成列引用,确认无活引用(或唯一活引用是 UPDATE OF 列清单里的触发器,见下方
-- 各段说明)。无盲目 CASCADE 删活对象。
--
-- 来由(每项):
--   1. usage_events —— billing-v2 孤儿。同批 packs / ledger_entries / topups /
--      billing_ledger 已在 20260603112148_drop_billing_v2_orphans.sql + 0033/v2 清掉,
--      唯它当时漏(其唯一入站 FK 来自 ledger_entries.usage_event_id,该表已 DROP CASCADE,
--      故现无入站 FK)。全仓无 INSERT/SELECT。删表(连带 5 个 index + RLS
--      usage_events_owner_read + grant 由 CASCADE 清掉)。
--   2. temporary_group_meta.cloud_machine_id —— 二次被取代的死列(fly_machine_id 取代其
--      语义,fly_machine_id 又在 20260614123750 被 machine_id 取代)。现存两个 crew view
--      (crew_resolved_responsibility_shares / crew_link_summaries)均不 SELECT 它;无
--      生成列 / FK / 触发器引用。普通 DROP COLUMN 即可。
--   3. users.balance_credits + lifetime_topup_credits + lifetime_spent_credits ——
--      billing-v1 僵尸列。R3 已删读它们的 edge 代码(/v1/me/balance + getBalance)。
--      新计费走 WalletDO/Polar + pnc_ledger,不读这三列。无 view / 生成列 / RLS 引用。
--      唯一活引用:触发器 users_ensure_subject_trg 的 UPDATE OF 列清单里列了这三列
--      (20260524084417_subject_foundation.sql)。该触发器体只 PERFORM ensure_user_subject
--      (NEW.id),而 ensure_user_subject 在 20260604123212 已改写成只读 display_name/email、
--      不再碰余额 —— 即这三列早已对该触发器无意义。故重建触发器、把这三列从 UPDATE OF
--      移出(行为保持:触发器仍在 display_name/email/balance_updated_at 上触发),再删列。
--      注:balance_updated_at 是同族第 4 个 v1 僵尸列,本次未授权删,保留(仍留在 UPDATE OF)。
--   4. (ai_picks 疑似胎死,但用户对它仅回答「这是什么」= 问而非授权;本迁移**不含**
--      ai_picks drop,待明确确认后单独处理。)
--   5. users.is_admin + 两条只 gate 不存在直连 authenticated 角色的 admin RLS 策略 ——
--      board 门禁已迁 Cloudflare Access,该列对 board dead。
--        * billing_config_admin_write (ON billing_config) —— 表保留,只删此策略。
--        * redemption_codes_admin     (ON redemption_codes) —— 表保留,只删此策略。
--      另两条曾读 is_admin 的策略(topups_admin_all / billing_ledger_admin_all)已随
--      topups / billing_ledger 表在 20260603112148 DROP CASCADE 一并消失,无需处理。
--      读 is_admin 的两个 admin RPC(billing_issue_codes / billing_admin_grant)亦已在
--      20260603112148 DROP,无活 RPC 读 is_admin。
--      唯一剩余活引用:审计触发器 users_is_admin_audit(UPDATE OF is_admin,
--      20260511160952)—— 其唯一职责就是审计这列,随列退役一并删(连同触发函数)。

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- 1. usage_events 表(审计 Y7;billing-v2 漏网孤儿,补 20260603112148 之缺)
-- ─────────────────────────────────────────────────────────────────────
-- CASCADE 清掉其 5 个 index + RLS usage_events_owner_read + grant。
-- 入站 FK(ledger_entries.usage_event_id)已随 ledger_entries 表先期 DROP。
DROP TABLE IF EXISTS pendingbot.usage_events CASCADE;

-- ─────────────────────────────────────────────────────────────────────
-- 2. temporary_group_meta.cloud_machine_id 列(审计 G16;二次被取代死列)
-- ─────────────────────────────────────────────────────────────────────
ALTER TABLE pendingbot.temporary_group_meta
  DROP COLUMN IF EXISTS cloud_machine_id;

-- ─────────────────────────────────────────────────────────────────────
-- 3. users.is_admin 退役(审计 G16;board 门禁已迁 Cloudflare Access)
--    顺序:先删 gate 它的两条 RLS 策略 + 阻断 DROP 的审计触发器,再删列。
-- ─────────────────────────────────────────────────────────────────────

-- 3a. 两条只 gate 不存在直连 authenticated 角色的 admin 策略(表保留)。
DROP POLICY IF EXISTS billing_config_admin_write ON pendingbot.billing_config;
DROP POLICY IF EXISTS redemption_codes_admin ON pendingbot.redemption_codes;

-- 3b. is_admin 审计触发器 + 触发函数(职责仅审计 is_admin;UPDATE OF is_admin
--     会硬阻断列 DROP,且列退役后审计无意义)。
DROP TRIGGER IF EXISTS users_is_admin_audit ON pendingbot.users;
DROP FUNCTION IF EXISTS pendingbot.tg_users_is_admin_audit() CASCADE;

-- 3c. 删列。
ALTER TABLE pendingbot.users
  DROP COLUMN IF EXISTS is_admin;

-- ─────────────────────────────────────────────────────────────────────
-- 4. users 上 billing-v1 三个僵尸余额列(审计 G16;R3 已删读它们的 edge)
--    顺序:先重建 users_ensure_subject_trg 去掉这三列(UPDATE OF 列清单引用会
--    硬阻断 DROP COLUMN),再删列。触发函数体不变(只 PERFORM ensure_user_subject)。
-- ─────────────────────────────────────────────────────────────────────

-- 4a. 重建触发器,把 balance_credits / lifetime_topup_credits / lifetime_spent_credits
--     移出 UPDATE OF。保留 display_name / email / balance_updated_at(后者本次未删)。
--     触发函数 tg_users_ensure_subject() 不动 —— 其体早已不读这三列。
DROP TRIGGER IF EXISTS users_ensure_subject_trg ON pendingbot.users;
CREATE TRIGGER users_ensure_subject_trg
AFTER INSERT OR UPDATE OF display_name, email, balance_updated_at
ON pendingbot.users
FOR EACH ROW
EXECUTE FUNCTION pendingbot.tg_users_ensure_subject();

-- 4b. 删三列。
ALTER TABLE pendingbot.users
  DROP COLUMN IF EXISTS balance_credits,
  DROP COLUMN IF EXISTS lifetime_topup_credits,
  DROP COLUMN IF EXISTS lifetime_spent_credits;

-- (ai_picks drop 已移出本迁移 —— 待用户明确确认,见文件头注释第 4 项。)

COMMIT;
