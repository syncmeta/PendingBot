-- 审计 G16 尾巴 — drop ai_picks 表（用户 2026-06-16 明确授权删）。
-- ai_picks 自 0001_init 建表起从未接任何代码（全仓仅 0001 DDL + 0031 一条注释示例引用）；
-- 无 view / 入站 FK / 触发器 / RPC body 引用。CASCADE 连带 PK + idx_ai_picks_user_time
-- + 出站 FK ai_picks_user_id_fkey + RLS picks_self + grant。
-- （从 20260616024230 摘出后单独 drop —— 已应用的迁移不可改，故新建本迁移。）
DROP TABLE IF EXISTS pendingbot.ai_picks CASCADE;
