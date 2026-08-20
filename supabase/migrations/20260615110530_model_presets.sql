-- 模型预设：board 管理"规则"，内容由 OpenRouter 目录动态解析（见 apps/edge/src/lib/model-presets.ts）。
-- bot 存预设引用（config.modelPool.presets），对话时解析成模型并集。
create table pendingbot.model_presets (
  slug text primary key,
  title text not null,
  description text not null default '',
  resolver_kind text not null check (resolver_kind in (
    'top_flagship', 'chinese_flagship', 'latest_per_vendor', 'fastest', 'most_popular', 'manual'
  )),
  params jsonb not null default '{}'::jsonb,
  default_selected boolean not null default false,
  enabled boolean not null default true,
  sort_order integer not null default 100,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- RLS 锁死：无 policy = 默认拒绝 anon/authenticated 直接访问。
-- /v1/model-presets 端点与 board 都走 service role（绕过 RLS）。
alter table pendingbot.model_presets enable row level security;

insert into pendingbot.model_presets (slug, title, description, resolver_kind, params, default_selected, sort_order) values
  ('top-flagship', '头两家旗舰', 'OpenAI 与 Anthropic 的旗舰模型', 'top_flagship',
   '{"authors":["openai","anthropic"],"flagship":"most_expensive"}'::jsonb, true, 10),
  ('cn-flagship', '中国旗舰', '国内头部厂商的旗舰模型', 'chinese_flagship',
   '{"authors":["deepseek","qwen","moonshotai","z-ai","minimax"],"flagship":"most_expensive"}'::jsonb, true, 20),
  ('latest-per-vendor', '各家最新', '每家厂商最新发布的模型', 'latest_per_vendor',
   '{"count":8}'::jsonb, true, 30),
  ('fastest', '速度快', '吞吐最高的模型', 'fastest',
   '{"count":5,"min_rating":1200}'::jsonb, false, 40),
  ('most-popular', '最热门', '评分最高的热门模型', 'most_popular',
   '{"count":5}'::jsonb, false, 50);
