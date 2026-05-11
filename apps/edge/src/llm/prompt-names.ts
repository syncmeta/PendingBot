// Pure constant export of prompt names. Separate file (no .md imports) so
// Board can import it without pulling in wrangler-specific text loaders.
//
// Edits here must match the PROMPTS_ZH map in prompt-loader.ts.

export const PROMPT_NAMES = [
  'system',
  'identity-quest',
  'scroll',
  'scroll-injected',
  'scroll-write',
  'scroll-collaborator',
  'title',
  'group-router',
] as const;

export type PromptName = (typeof PROMPT_NAMES)[number];

// Short human-readable description for each prompt — surfaced in the Board
// list view so it's clear what each name does without reading the .md.
export const PROMPT_DESCRIPTIONS: Record<PromptName, string> = {
  'system': '主 system prompt：定义平台身份、消息格式、调用约定',
  'identity-quest': '新机器人首次出场前的"身份问询"，引导用户填关键信息',
  'scroll': '奏折主 system prompt：bot 给用户写一篇文章的整体指令',
  'scroll-injected': '奏折注入段：把任务背景注入到 system 末尾的额外指令',
  'scroll-write': '奏折"写正文"阶段的 system prompt',
  'scroll-collaborator': '奏折协作者视角的提示',
  'title': '会话标题自动生成 prompt',
  'group-router': '群聊调度器：判断每轮该唤醒哪些 bot',
};
