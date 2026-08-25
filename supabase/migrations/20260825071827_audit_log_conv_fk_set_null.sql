-- audit_log.conversation_id 外键改成 ON DELETE SET NULL。
--
-- 病：失败回合的 audit 行是异步排队写的（enqueueAudit → AUDIT_QUEUE →
-- persistAuditMessage 的 upsert）。而 `POST /v1/messages/start` 在这一轮没有
-- 产出任何用户可见内容时，会把刚建的会话整条删掉做回滚
-- （routes/messages.ts 的 `if (!producedOutput)` 分支，CASCADE 连带参与者和
-- 用户消息）。等队列消费到那条 audit 消息时，它要指向的会话已经不存在，
-- 这条 FK（原来没有 ON DELETE 子句 = NO ACTION）拒绝插入 → upsert 抛错 →
-- 队列重试 → 会话不会自己回来，所以 5 次必然全败 → 进 pendingbot-audit-dlq。
--
-- 结果：**每一次「第一条消息就失败」都把自己的证据销毁了**。线上实证：
-- audit_log 自 2026-06-04 建库至今 status='error' 的行数是 0，而同期成功行
-- 一切正常（详见 docs/tech-debt.md 的对应条目）。
--
-- 修：会话被删时把 audit 行的 conversation_id 置空，保留这一行。这与删账号
-- 触发器（0052）里的处理方式一致 —— 那里本来就是先 `update audit_log set
-- conversation_id = null` 再删会话，只是当时没把 FK 本身改掉，所以只有走那条
-- 触发器的路径受保护，会话级删除仍然会撞上。
--
-- 语义上这是对的：audit_log 是「这次调用发生过什么」的账，它不该因为承载
-- 它的会话被回滚/删除而消失；丢掉的只是「属于哪个会话」这条关联。

alter table pendingbot.audit_log
  drop constraint audit_log_conversation_id_fkey;

alter table pendingbot.audit_log
  add constraint audit_log_conversation_id_fkey
  foreign key (conversation_id)
  references pendingbot.conversations(id)
  on delete set null;
