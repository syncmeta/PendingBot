-- 20260511064939_i18n_prompts.sql
--
-- AI prompt 内容从仓库 .md 文件搬到 DB，由 Board (admin)/prompts/ 页面在线
-- 编辑，免去"改一句话 → 提 PR → 等部署"的循环。
--
-- 加载策略 (apps/edge/src/llm/prompt-loader.ts):
--   1. 启动期/请求期 preload，读取 i18n_prompts 全表到 isolate-local Map
--   2. getPrompt(name, locale) 命中 cache 则返回 DB 内容
--   3. 未命中 (DB 行不存在或表空) 回退到 wrangler bundled .md 文件
--
-- 这意味着：
--   * 应用本 migration 后 i18n_prompts 是空表，edge worker 行为完全不变
--     (一直走 bundled .md)
--   * 一旦 Board 写入第一条 (name, locale) → 该 prompt 切换到 DB 内容
--   * 删除 DB 行 → 自动 fallback 回 bundled
--
-- (name, locale) 主键避免重复；version 字段为未来回滚 / 审计预留；
-- updated_by 关联 auth.users 用于"谁改的"显示。
--
-- 表归服务端独占 (edge worker + board admin)。RLS 开启但无 policy =
-- 普通用户客户端永远读不到 (符合 Supabase RLS-by-default 约定)。

BEGIN;

CREATE TABLE pendingbot.i18n_prompts (
  name        text NOT NULL,
  locale      text NOT NULL,
  body_md     text NOT NULL,
  version     int  NOT NULL DEFAULT 1,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  PRIMARY KEY (name, locale)
);

ALTER TABLE pendingbot.i18n_prompts OWNER TO postgres;
ALTER TABLE pendingbot.i18n_prompts ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE pendingbot.i18n_prompts IS
  'AI prompt 内容的 DB 覆盖层。空表时 edge 走 bundled .md fallback。Board (admin)/prompts/ 编辑器写这张表。';
COMMENT ON COLUMN pendingbot.i18n_prompts.name IS
  'prompt 名，与 apps/edge/prompts/<locale>/<name>.md 的 basename 对应。';
COMMENT ON COLUMN pendingbot.i18n_prompts.locale IS
  'BCP-47 base tag (zh, en, ...)，与 apps/edge/src/i18n/types.ts 的 SUPPORTED_LOCALES 一致。';
COMMENT ON COLUMN pendingbot.i18n_prompts.version IS
  '每次 update 时 +1，留作回滚 / 审计基础。当前 UI 不展开。';

COMMIT;
