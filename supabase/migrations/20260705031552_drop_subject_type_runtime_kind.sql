-- 双写收口 Phase 2(不可逆段)— drop 旧列 + 同步触发器。
--
-- 前置(20260705030253 + 20260705031227,Phase 1)已把全部读写点切到
-- kind / runtime_location。drop 前 live 复核(2026-07-05):
--   * subjects: 3 行,subject_type IS DISTINCT FROM kind 计 0(零漂移);
--   * temporary_group_meta: 0 行;
--   * pg_depend 上两列的残余依赖仅剩:各自的列默认值 / 单列 CHECK
--     (随列自动 drop),以及 subjects_sync_kind_trg(本迁移先 drop)。
--     无视图 / 索引 / RLS / 生成列 / FK 引用。
--
-- 第三组双写(fly_machine_id ↔ cloud_machine_id)无需处理:两列已在
-- 20260614123750 / 20260616024230 被 machine_id 取代并 drop。

BEGIN;

-- 1) 同步触发器 + 触发函数(唯一职责是 kind ↔ subject_type 镜像,随列退役)
DROP TRIGGER IF EXISTS subjects_sync_kind_trg ON pendingbot.subjects;
DROP FUNCTION IF EXISTS pendingbot.tg_subjects_sync_kind();

-- 2) subjects.subject_type(subjects_subject_type_check 随列 drop)
ALTER TABLE pendingbot.subjects
  DROP COLUMN IF EXISTS subject_type;

-- 3) temporary_group_meta.runtime_kind
--    (default 'local' + temporary_group_meta_runtime_kind_chk 随列 drop)
ALTER TABLE pendingbot.temporary_group_meta
  DROP COLUMN IF EXISTS runtime_kind;

COMMIT;
