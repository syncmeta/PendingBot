-- T2.1 — Crew v2 schema 扩展(spec v2 §6 / §8.2)。
--
-- 物理表是 `temporary_group_meta`(在 `20260524085639_temporary_groups_crew_schema.sql`
-- 创建,`temporary_kind='crew'` 时即逻辑上的 "crew" 行)。本迁移只为 crew 行加列,
-- 不重命名表(老代码大量引用 `temporary_group_meta`)。
--
-- 加列:
--   * runtime_location text('local_host' | 'peer_device' | 'fly_machine')
--     — spec v2 §8.2 的三种 Runtime Location。
--     — 旧 `runtime_kind`('local' | 'cloud')保留并加 COMMENT 注明 deprecation 意图,
--       回填映射:'local' → 'local_host','cloud' → 'fly_machine'。
--   * tag text — spec v2 §6.2:自由分类标签(原"项目"概念重命名为"标签")。
--   * working_directory text — crew 的工作目录(local_host 时是 host 上的路径)。
--   * peer_device_id uuid — runtime_location='peer_device' 时引用 user_devices(id)。
--   * fly_machine_id text — runtime_location='fly_machine' 时的 fly 机器 id(字符串)。
--
-- 旧字段保留(不动):
--   * runtime_kind:仍被现有 RPC / view 使用;deprecation 通过 comment 标注;
--     新代码统一读 runtime_location,过渡期由触发器双写。
--   * cloud_machine_id:被现有 view 引用,保留;新字段 fly_machine_id 取代它的语义。
--
-- 不引入新 enum 类型(项目里 enum 一律用 text + CHECK,统一风格)。

BEGIN;

SET search_path TO pendingbot, public;

-- ────────────────────────────────────────────────────────────────────
-- 1) 加列(均 nullable / 带默认)
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.temporary_group_meta
  ADD COLUMN IF NOT EXISTS runtime_location text,
  ADD COLUMN IF NOT EXISTS tag text,
  ADD COLUMN IF NOT EXISTS working_directory text,
  ADD COLUMN IF NOT EXISTS peer_device_id uuid,
  ADD COLUMN IF NOT EXISTS fly_machine_id text;

-- 2) 回填 runtime_location ← 老 runtime_kind 的映射
UPDATE pendingbot.temporary_group_meta
   SET runtime_location = CASE runtime_kind
                            WHEN 'local' THEN 'local_host'
                            WHEN 'cloud' THEN 'fly_machine'
                            ELSE 'local_host'
                          END
 WHERE runtime_location IS NULL;

-- 3) 设默认 + NOT NULL + CHECK
ALTER TABLE pendingbot.temporary_group_meta
  ALTER COLUMN runtime_location SET DEFAULT 'local_host';

ALTER TABLE pendingbot.temporary_group_meta
  ALTER COLUMN runtime_location SET NOT NULL;

ALTER TABLE pendingbot.temporary_group_meta
  DROP CONSTRAINT IF EXISTS temporary_group_meta_runtime_location_chk;
ALTER TABLE pendingbot.temporary_group_meta
  ADD CONSTRAINT temporary_group_meta_runtime_location_chk
  CHECK (runtime_location IN ('local_host', 'peer_device', 'fly_machine'));

-- 4) peer_device / fly_machine FK + 语义一致性(只在新字段非空时校验)
-- 注:user_devices 是迁移 20260524122559 创建的;若 schema 中表名不同请改这里。
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'pendingbot' AND table_name = 'user_devices'
  ) THEN
    -- 加 FK(若未加过)
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
       WHERE conname = 'temporary_group_meta_peer_device_fk'
    ) THEN
      ALTER TABLE pendingbot.temporary_group_meta
        ADD CONSTRAINT temporary_group_meta_peer_device_fk
        FOREIGN KEY (peer_device_id) REFERENCES pendingbot.user_devices(id) ON DELETE SET NULL;
    END IF;
  END IF;
END $$;

-- 5) runtime_location vs *_id 一致性 check
ALTER TABLE pendingbot.temporary_group_meta
  DROP CONSTRAINT IF EXISTS temporary_group_meta_runtime_target_chk;
ALTER TABLE pendingbot.temporary_group_meta
  ADD CONSTRAINT temporary_group_meta_runtime_target_chk
  CHECK (
    (runtime_location = 'local_host'   AND peer_device_id IS NULL AND fly_machine_id IS NULL)
    OR (runtime_location = 'peer_device' AND peer_device_id IS NOT NULL AND fly_machine_id IS NULL)
    OR (runtime_location = 'fly_machine' AND fly_machine_id IS NOT NULL AND peer_device_id IS NULL)
  );

-- 6) 索引
CREATE INDEX IF NOT EXISTS temporary_group_meta_tag_idx
  ON pendingbot.temporary_group_meta(tag)
  WHERE tag IS NOT NULL;

CREATE INDEX IF NOT EXISTS temporary_group_meta_runtime_location_idx
  ON pendingbot.temporary_group_meta(runtime_location);

CREATE INDEX IF NOT EXISTS temporary_group_meta_peer_device_idx
  ON pendingbot.temporary_group_meta(peer_device_id)
  WHERE peer_device_id IS NOT NULL;

-- 7) COMMENT 注明老字段的 deprecation 意图(不动数据 / 不动现有代码)
COMMENT ON COLUMN pendingbot.temporary_group_meta.runtime_kind IS
  'DEPRECATED in spec v2 — read runtime_location instead. Kept for legacy RPC / view compatibility; new code MUST write runtime_location.';
COMMENT ON COLUMN pendingbot.temporary_group_meta.cloud_machine_id IS
  'DEPRECATED in spec v2 — use fly_machine_id for fly-hosted runtime; this column was the v1 cloud-machine pointer and is no longer authoritative.';
COMMENT ON COLUMN pendingbot.temporary_group_meta.runtime_location IS
  'spec v2 §8.2: local_host (Mac App) | peer_device (other peer device of the same user / group member) | fly_machine (managed cloud machine).';
COMMENT ON COLUMN pendingbot.temporary_group_meta.tag IS
  'spec v2 §6.2: free-form classification tag (renamed from "project"). No FK / no uniqueness.';
COMMENT ON COLUMN pendingbot.temporary_group_meta.working_directory IS
  'Host working directory for local_host / peer_device runs; ignored for fly_machine (managed).';
COMMENT ON COLUMN pendingbot.temporary_group_meta.peer_device_id IS
  'FK pendingbot.user_devices(id). NOT NULL iff runtime_location = peer_device.';
COMMENT ON COLUMN pendingbot.temporary_group_meta.fly_machine_id IS
  'fly.io machine id (string). NOT NULL iff runtime_location = fly_machine.';

COMMIT;
