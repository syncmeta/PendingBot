-- T1.3: device-login challenge 增加可选 requested_subject_id
--
-- 发起端 (PendingCrew 桌面) 在创建 challenge 时可以预声明 "我想以这个
-- subject 身份登录"。这是个提示, 不在 challenge 创建时校验权限 (因为
-- 发起端通常匿名 / 还未拿到 session)。
--
-- 真正的权限校验在 approve 阶段, 已经通过 RPC
-- pendingbot.subject_can_authorize_device_grant 完成 (见
-- 20260524122559_subject_device_login_grants.sql)。
--
-- 但 approve 阶段要做一项额外的反欺骗检查 (在 edge route 层做, 不在 SQL):
-- 如果 challenge.requested_subject_id 非空, approve 请求里的 subjectId
-- 必须匹配 — 防止 "PendingBot 用户被诱导以一个非预期身份签字"。

ALTER TABLE pendingbot.subject_device_login_challenges
  ADD COLUMN IF NOT EXISTS requested_subject_id uuid
    REFERENCES pendingbot.subjects(id)
    ON DELETE SET NULL;

COMMENT ON COLUMN pendingbot.subject_device_login_challenges.requested_subject_id IS
  'Optional hint from challenge creator: which subject should the approving '
  'user log in as. Approve must match this if non-null. NULL = no hint, '
  'approver picks freely.';
