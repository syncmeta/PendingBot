// Pure constant export of prompt names. Separate file (no .md imports) so
// Board can import it without pulling in wrangler-specific text loaders.
//
// Edits here must match the PROMPTS_ZH map in prompt-loader.ts.

export const PROMPT_NAMES = [
  'system',
  'voice',
  'group-voice',
  'identity-quest',
  'envelope',
  'envelope-injected',
  'envelope-write',
  'envelope-collaborator',
  'title',
  'group-router',
  'bot-social-graph',
  'session-world-model',
  'start-crew-tool-result',
] as const;

export type PromptName = (typeof PROMPT_NAMES)[number];

// Short human-readable description for each prompt — surfaced in the Board
// list view so it's clear what each name does without reading the .md.
export const PROMPT_DESCRIPTIONS: Record<PromptName, string> = {
  'system': '主 system prompt：定义平台身份、消息格式、调用约定',
  'voice': '1:1 语音通话 system prompt：口语化、无 markdown/分段、可挂断',
  'group-voice': '群语音通话 system prompt：多人在场、别抢话、轮到才说',
  'identity-quest': '新机器人首次出场前的"身份问询"，引导用户填关键信息',
  'envelope': '来信主 system prompt：bot 给用户写一篇文章的整体指令',
  'envelope-injected': '来信注入段：把任务背景注入到 system 末尾的额外指令',
  'envelope-write': '来信"写正文"阶段的 system prompt',
  'envelope-collaborator': '来信协作者视角的提示',
  'title': '会话标题自动生成 prompt',
  'group-router': '群聊调度器：判断每轮该唤醒哪些 bot',
  'bot-social-graph': '永远注入：解释 bot 对自己社交圈、好友可见性、ask_friend/delegate 工具语义的固有常识',
  'session-world-model': 'Crew session 世界观（spec v2 §9.5）：身份/IO/群聊定位/captain/拍板方/post_to_crew/读白板/permission 模式。每个 session 启动时由 edge 渲染填值后注入。',
  'start-crew-tool-result': 'start_crew 工具调用成功后返回给 bot 的提示（已发出 crew 创建提议，等用户确认）',
};
