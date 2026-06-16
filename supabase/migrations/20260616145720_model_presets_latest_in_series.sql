-- 旗舰预设从 most_expensive 改为 latest_in_series。
--
-- 病根：most_expensive 按 blended 价降序取每家第一，但"最贵"≠"最新旗舰"——实测
-- openai 选出 o1-pro(2025-03 老款)、deepseek 选出 r1-distill(蒸馏小模型)，中国厂
-- 定价又全 ~$0/M 无区分度。改为"产品线系列锚点 + 系列内取发布日最新(排除小号/特化/
-- 滚动别名)"，即用户要的 "opus latest / gpt latest / kimi latest"。解析逻辑见
-- apps/edge/src/lib/model-presets.ts 的 latest_in_series 分支 + isNonFlagshipVariant。

-- check 约束补 latest_in_series（其余 kind 保留：board 仍可给别的预设用）。
alter table pendingbot.model_presets
  drop constraint if exists model_presets_resolver_kind_check;
alter table pendingbot.model_presets
  add constraint model_presets_resolver_kind_check
  check (resolver_kind in (
    'top_flagship', 'chinese_flagship', 'latest_per_vendor',
    'fastest', 'most_popular', 'manual', 'latest_in_series'
  ));

-- 头两家旗舰：anthropic opus 线 + openai gpt-5 线。
update pendingbot.model_presets set
  resolver_kind = 'latest_in_series',
  params = '{"lines":[{"author":"anthropic","series":"claude-opus"},{"author":"openai","series":"gpt-5"}]}'::jsonb,
  updated_at = now()
where slug = 'top-flagship';

-- 中国旗舰：各家主力产品线（deepseek-v / qwen3 / kimi / glm / minimax-m）。
update pendingbot.model_presets set
  resolver_kind = 'latest_in_series',
  params = '{"lines":[{"author":"deepseek","series":"deepseek-v"},{"author":"qwen","series":"qwen3"},{"author":"moonshotai","series":"kimi"},{"author":"z-ai","series":"glm"},{"author":"minimax","series":"minimax-m"}]}'::jsonb,
  updated_at = now()
where slug = 'cn-flagship';
