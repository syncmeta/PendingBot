-- Skills get a provider scope so the iOS "机器人能力扩展" UI can
-- show user-customized skills under either OpenAI native or
-- OpenRouter. Existing rows (including seeded anthropic presets)
-- default to 'openrouter' — that's where the preset code-runner /
-- mcp-builder / skill-creator are meant to run; OpenAI side uses
-- native code interpreter + native search instead of those skills.

alter table pendingbot.skills
  add column provider text not null default 'openrouter'
  check (provider in ('openrouter', 'openai'));

-- Hot path: persona-cache filters subscribed skills by bot.model_provider.
create index if not exists skills_provider_idx
  on pendingbot.skills (provider);
