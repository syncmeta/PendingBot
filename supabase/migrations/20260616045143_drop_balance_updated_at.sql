-- 审计 Y7 尾巴 — drop users.balance_updated_at（billing-v1 第 4 个同族僵尸列，用户 2026-06-16 授权清）。
-- 同族 balance_credits / lifetime_topup_credits / lifetime_spent_credits 已在 20260616024230 删。
-- 唯一活引用是 users_ensure_subject_trg 的 UPDATE OF 列清单（其触发函数 tg_users_ensure_subject
-- 只 PERFORM ensure_user_subject，只读 display_name/email，不读该列）。先重建触发器移出它，再删列。
DROP TRIGGER IF EXISTS users_ensure_subject_trg ON pendingbot.users;
CREATE TRIGGER users_ensure_subject_trg
AFTER INSERT OR UPDATE OF display_name, email
ON pendingbot.users
FOR EACH ROW
EXECUTE FUNCTION pendingbot.tg_users_ensure_subject();
ALTER TABLE pendingbot.users DROP COLUMN IF EXISTS balance_updated_at;
