-- 注销账号时 `envelope_runs.author_user_id` 走 ON DELETE SET NULL,
-- 会把 kind='human' 行的 author 置 NULL,违反 envelope_runs_kind_shape_check
-- (人类来信要求 author_user_id NOT NULL),导致 auth.users 删除失败。
--
-- 改成 CASCADE:作者注销时,其发出的"人类来信"一并删除。和同表
-- user_id(收信人)的 CASCADE 对称,也与 messages 的"用户注销时其
-- 发出的消息一并删除"一致。

BEGIN;

ALTER TABLE pendingbot.envelope_runs
  DROP CONSTRAINT IF EXISTS envelope_runs_author_fkey;

ALTER TABLE pendingbot.envelope_runs
  ADD CONSTRAINT envelope_runs_author_fkey
    FOREIGN KEY (author_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

COMMIT;
