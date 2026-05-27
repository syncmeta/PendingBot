-- 6 个预置机器人（'Lorem ipsum' 词表）。幂等 —— 以 slug 为键。
-- 每个用固定 UUID v7，跨环境的会话链接 / 预置会话标题才稳定。
--
-- 全部 private —— 公开档已在 20260527091508_drop_public_open_visibility
-- 中废除，原来的 6 个 public_open 共享行随之删除，不再 seed。
--
-- 私有预置 bot 的 creator_id-NULL 行是「模板」：RLS 对所有人不可见，
-- 永不直接挂到会话上。bootstrap_user_id 在每个新用户 onboarding 时把
-- 模板克隆成一份 creator_id = 该用户 的私有 bot（见迁移
-- 20260517134853_preset_bots_per_user）。
--
-- ON CONFLICT 只刷 roster 字段（名字 / 模型 / 输出模式 / 启用 / 可见性），
-- 不动 config 和时间戳，方便重跑刷新而不冲掉运行期改动。

-- ── private（每用户克隆的模板） ──────────────────────────────────────
INSERT INTO pendingbot.bots (id, slug, display_name, model_id, output_mode, is_active, config, visibility, created_at, updated_at) VALUES ('019de705-aaf5-7105-861c-cd0153e4b2fc', 'amet', 'Amet', 'z-ai/glm-5.1', 'single', true, '{}', 'private', '2026-05-02 04:50:01.567472+00', '2026-05-02 04:50:01.567472+00') ON CONFLICT (slug) DO UPDATE SET display_name = EXCLUDED.display_name, model_id = EXCLUDED.model_id, output_mode = EXCLUDED.output_mode, is_active = EXCLUDED.is_active, visibility = EXCLUDED.visibility;
INSERT INTO pendingbot.bots (id, slug, display_name, model_id, output_mode, is_active, config, visibility, created_at, updated_at) VALUES ('019de705-aaf5-7392-b903-d52d343f94d6', 'consectetur', 'Consectetur', 'qwen3.6-plus', 'single', true, '{}', 'private', '2026-05-02 04:50:01.567472+00', '2026-05-02 04:50:01.567472+00') ON CONFLICT (slug) DO UPDATE SET display_name = EXCLUDED.display_name, model_id = EXCLUDED.model_id, output_mode = EXCLUDED.output_mode, is_active = EXCLUDED.is_active, visibility = EXCLUDED.visibility;
INSERT INTO pendingbot.bots (id, slug, display_name, model_id, output_mode, is_active, config, visibility, created_at, updated_at) VALUES ('019de67e-ea72-7812-b7ba-05ce4b8bcc8d', 'eiusmod', 'Eiusmod', 'claude-sonnet-4.6', 'single', true, '{}', 'private', '2026-05-02 02:22:50.463821+00', '2026-05-02 02:22:50.463821+00') ON CONFLICT (slug) DO UPDATE SET display_name = EXCLUDED.display_name, model_id = EXCLUDED.model_id, output_mode = EXCLUDED.output_mode, is_active = EXCLUDED.is_active, visibility = EXCLUDED.visibility;
INSERT INTO pendingbot.bots (id, slug, display_name, model_id, output_mode, is_active, config, visibility, created_at, updated_at) VALUES ('019de705-aae5-75ee-9142-8be94b46e07d', 'lorem', 'Lorem', 'claude-opus-4.7', 'single', true, '{}', 'private', '2026-05-02 04:50:01.567472+00', '2026-05-02 04:50:01.567472+00') ON CONFLICT (slug) DO UPDATE SET display_name = EXCLUDED.display_name, model_id = EXCLUDED.model_id, output_mode = EXCLUDED.output_mode, is_active = EXCLUDED.is_active, visibility = EXCLUDED.visibility;
INSERT INTO pendingbot.bots (id, slug, display_name, model_id, output_mode, is_active, config, visibility, created_at, updated_at) VALUES ('019de705-aaf4-7863-87bb-c7ba7caa7743', 'sit', 'Sit', 'kimi-k2.6', 'single', true, '{}', 'private', '2026-05-02 04:50:01.567472+00', '2026-05-02 04:50:01.567472+00') ON CONFLICT (slug) DO UPDATE SET display_name = EXCLUDED.display_name, model_id = EXCLUDED.model_id, output_mode = EXCLUDED.output_mode, is_active = EXCLUDED.is_active, visibility = EXCLUDED.visibility;
INSERT INTO pendingbot.bots (id, slug, display_name, model_id, output_mode, is_active, config, visibility, created_at, updated_at) VALUES ('019de3f7-ccda-7a9f-a64a-3d42129ba479', 'tempor', 'Tempor', 'gemma-4-31b-it', 'single', true, '{}', 'private', '2026-05-01 14:36:01.101808+00', '2026-05-01 14:36:01.101808+00') ON CONFLICT (slug) DO UPDATE SET display_name = EXCLUDED.display_name, model_id = EXCLUDED.model_id, output_mode = EXCLUDED.output_mode, is_active = EXCLUDED.is_active, visibility = EXCLUDED.visibility;
