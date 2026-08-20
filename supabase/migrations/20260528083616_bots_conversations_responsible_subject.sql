-- spec v2 §4.1 / §4.2:每个 crew / temporary group / session / runner host /
-- fly machine 都绑唯一 responsible_subject_id。这一步把 bots 和
-- conversations 也加上(渐进迁移:nullable + 回填 owner 的 user subject)。
--
-- 1. 加列(nullable -- 不能 not null,要先回填)
-- 2. 回填: bots -> creator_id 对应 user_account subject
--          conversations -> user_id 对应 user_account subject
-- 3. 加索引

BEGIN;

SET search_path TO pendingbot, public;

ALTER TABLE pendingbot.bots
  ADD COLUMN IF NOT EXISTS responsible_subject_id uuid
    REFERENCES pendingbot.subjects(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.conversations
  ADD COLUMN IF NOT EXISTS responsible_subject_id uuid
    REFERENCES pendingbot.subjects(id) ON DELETE SET NULL;

-- 确保所有 user 都有 user_account subject(老 plan 的回填只对了「迁移当时」的 users,
-- 但触发器在 INSERT 时才挂,所以这里再兜底一次)
INSERT INTO pendingbot.subjects(subject_type, kind, user_id, display_name, created_by)
SELECT 'user_account', 'user_account', u.id,
       COALESCE(NULLIF(u.display_name, ''), u.email, '你'),
       u.id
  FROM pendingbot.users u
 WHERE NOT EXISTS (
   SELECT 1 FROM pendingbot.subjects s
    WHERE s.kind = 'user_account' AND s.user_id = u.id
 );

INSERT INTO pendingbot.subject_wallets(subject_id)
SELECT s.id
  FROM pendingbot.subjects s
 WHERE s.kind = 'user_account'
   AND NOT EXISTS (
     SELECT 1 FROM pendingbot.subject_wallets w
      WHERE w.subject_id = s.id
   );

-- bots.responsible_subject_id 回填: creator_id 对应的 user_account subject
-- preset bots (creator_id IS NULL) 留 NULL,等运营/扫码后续逻辑分配
UPDATE pendingbot.bots b
   SET responsible_subject_id = s.id
  FROM pendingbot.subjects s
 WHERE s.kind = 'user_account'
   AND s.user_id = b.creator_id
   AND b.responsible_subject_id IS NULL;

-- conversations.responsible_subject_id 回填: user_id 对应的 user_account subject
-- bot-only / system conversations (user_id IS NULL) 留 NULL
UPDATE pendingbot.conversations c
   SET responsible_subject_id = s.id
  FROM pendingbot.subjects s
 WHERE s.kind = 'user_account'
   AND s.user_id = c.user_id
   AND c.responsible_subject_id IS NULL;

CREATE INDEX IF NOT EXISTS bots_responsible_subject_idx
  ON pendingbot.bots(responsible_subject_id);

CREATE INDEX IF NOT EXISTS conversations_responsible_subject_idx
  ON pendingbot.conversations(responsible_subject_id);

COMMIT;
