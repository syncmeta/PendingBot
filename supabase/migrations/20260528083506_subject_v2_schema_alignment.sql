-- Subject schema alignment to spec v2 §4.2 (lightweight group accounts).
--
-- 关键调整（基于 docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md §4.2）:
--   * 群账号 = 独立创建的轻量对象, 不一定和某个 group conversation 一一绑定;
--     旅游、家用、临时团队都可以快速建一个群账号。
--   * 旧 schema 的 group_conversation_id 强约束保留为 nullable hint(legacy 用),
--     但用 NULL-friendly chk 允许 standalone group_account。
--   * 引入 spec v2 期望的字段名: kind (= subject_type 镜像), created_by。
--   * group_subject_members 引入 granted_by/granted_at(沿用 created_at)。
--   * subject_wallets 暴露 updated_at(镜像 balance_updated_at)。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1. subjects 表升级
-- ────────────────────────────────────────────────────────────────────

-- 1a. kind 字段(spec v2 命名),与 subject_type 同义
ALTER TABLE pendingbot.subjects
  ADD COLUMN IF NOT EXISTS kind text;

UPDATE pendingbot.subjects
   SET kind = subject_type
 WHERE kind IS NULL;

ALTER TABLE pendingbot.subjects
  ALTER COLUMN kind SET NOT NULL;

ALTER TABLE pendingbot.subjects
  DROP CONSTRAINT IF EXISTS subjects_kind_chk;
ALTER TABLE pendingbot.subjects
  ADD CONSTRAINT subjects_kind_chk
  CHECK (kind IN ('user_account', 'group_account'));

-- kind / subject_type 始终一致(任一插入都同步另一个)
CREATE OR REPLACE FUNCTION pendingbot.tg_subjects_sync_kind()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.kind IS NULL AND NEW.subject_type IS NOT NULL THEN
    NEW.kind := NEW.subject_type;
  ELSIF NEW.subject_type IS NULL AND NEW.kind IS NOT NULL THEN
    NEW.subject_type := NEW.kind;
  ELSIF NEW.kind <> NEW.subject_type THEN
    -- 上层只填一个就好; 不一致时以 kind 为准(spec v2 的字段)
    NEW.subject_type := NEW.kind;
  END IF;
  RETURN NEW;
END $$;

ALTER FUNCTION pendingbot.tg_subjects_sync_kind() OWNER TO postgres;

DROP TRIGGER IF EXISTS subjects_sync_kind_trg ON pendingbot.subjects;
CREATE TRIGGER subjects_sync_kind_trg
  BEFORE INSERT OR UPDATE OF kind, subject_type
  ON pendingbot.subjects
  FOR EACH ROW EXECUTE FUNCTION pendingbot.tg_subjects_sync_kind();

-- 1b. created_by 字段(spec v2 §4.2: 谁创建的群账号)
ALTER TABLE pendingbot.subjects
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES pendingbot.users(id) ON DELETE SET NULL;

-- 回填: user_account 的 created_by = 自己;
-- 已有 group_account(legacy 强绑了 group conversation)的 created_by 取 conversation_group_meta.created_by
UPDATE pendingbot.subjects s
   SET created_by = s.user_id
 WHERE kind = 'user_account'
   AND created_by IS NULL;

UPDATE pendingbot.subjects s
   SET created_by = cgm.created_by
  FROM pendingbot.conversation_group_meta cgm
 WHERE s.kind = 'group_account'
   AND s.created_by IS NULL
   AND s.group_conversation_id IS NOT NULL
   AND cgm.conversation_id = s.group_conversation_id;

-- 1c. 放宽 group_account 的 chk,允许"独立创建的群账号"(无 group_conversation_id)
ALTER TABLE pendingbot.subjects
  DROP CONSTRAINT IF EXISTS subjects_user_kind_chk;

ALTER TABLE pendingbot.subjects
  ADD CONSTRAINT subjects_user_kind_chk
  CHECK (
    (kind = 'user_account' AND user_id IS NOT NULL AND group_conversation_id IS NULL)
    OR
    (kind = 'group_account' AND user_id IS NULL)  -- group_conversation_id 可选
  );

-- 1d. 索引
CREATE INDEX IF NOT EXISTS subjects_kind_idx
  ON pendingbot.subjects(kind);

CREATE INDEX IF NOT EXISTS subjects_created_by_idx
  ON pendingbot.subjects(created_by);

-- ────────────────────────────────────────────────────────────────────
-- 2. group_subject_members: granted_by / granted_at
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.group_subject_members
  ADD COLUMN IF NOT EXISTS granted_by uuid REFERENCES pendingbot.users(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.group_subject_members
  ADD COLUMN IF NOT EXISTS granted_at timestamptz;

UPDATE pendingbot.group_subject_members
   SET granted_at = COALESCE(granted_at, created_at, now())
 WHERE granted_at IS NULL;

ALTER TABLE pendingbot.group_subject_members
  ALTER COLUMN granted_at SET DEFAULT now();

ALTER TABLE pendingbot.group_subject_members
  ALTER COLUMN granted_at SET NOT NULL;

-- 回填 granted_by: owner 是自己授予自己,其余暂时记 owner
UPDATE pendingbot.group_subject_members gsm
   SET granted_by = COALESCE(
     gsm.granted_by,
     gsm.user_id  -- 临时: owner 行自己授权自己
   )
 WHERE granted_by IS NULL;

-- ────────────────────────────────────────────────────────────────────
-- 3. subject_wallets: updated_at(暴露 spec 名)
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.subject_wallets
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

UPDATE pendingbot.subject_wallets
   SET updated_at = COALESCE(updated_at, balance_updated_at, now())
 WHERE updated_at IS NULL;

ALTER TABLE pendingbot.subject_wallets
  ALTER COLUMN updated_at SET DEFAULT now();

-- 保持 balance_updated_at 和 updated_at 同步(legacy 路径还在用 balance_updated_at)
CREATE OR REPLACE FUNCTION pendingbot.tg_subject_wallets_sync_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.updated_at IS NULL THEN
      NEW.updated_at := COALESCE(NEW.balance_updated_at, now());
    END IF;
    IF NEW.balance_updated_at IS NULL THEN
      NEW.balance_updated_at := NEW.updated_at;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    -- 任意余额变动 -> 两个时间戳都推进
    IF NEW.balance_credits IS DISTINCT FROM OLD.balance_credits
       OR NEW.lifetime_topup_credits IS DISTINCT FROM OLD.lifetime_topup_credits
       OR NEW.lifetime_spent_credits IS DISTINCT FROM OLD.lifetime_spent_credits THEN
      NEW.updated_at := now();
      NEW.balance_updated_at := NEW.updated_at;
    END IF;
  END IF;
  RETURN NEW;
END $$;

ALTER FUNCTION pendingbot.tg_subject_wallets_sync_updated_at() OWNER TO postgres;

DROP TRIGGER IF EXISTS subject_wallets_sync_updated_at_trg ON pendingbot.subject_wallets;
CREATE TRIGGER subject_wallets_sync_updated_at_trg
  BEFORE INSERT OR UPDATE
  ON pendingbot.subject_wallets
  FOR EACH ROW EXECUTE FUNCTION pendingbot.tg_subject_wallets_sync_updated_at();

COMMIT;
