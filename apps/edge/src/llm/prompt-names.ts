// Pure constant export of prompt names + descriptions.
//
// Langfuse is the source of truth for prompt *bodies* (keyed `<name>/<locale>`,
// production label). This list is the manifest the loader warms from KV and
// what the Board lists. Adding a prompt: add its name here, then create the
// `<name>/<locale>` prompt in Langfuse under the production label.

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
  'request-permission-tool-result',
  'lookback-instruction',
  'image-summary',
  'group-bot-intro',
  'output-mode-bubble',
  'output-mode-single',
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
  'request-permission-tool-result': 'request_permission 工具调用成功后返回给 agent 的提示（已发出权限申请卡片，manual 模式下等批准）',
  'lookback-instruction': 'Lookback 复盘任务指令：让 bot 回看刚才的对话、查证双方说法、写一段只给"未来的自己"看的短笔记或输出 [SILENT]',
  'image-summary': '识图摘要 prompt：让视觉模型输出严格 JSON（summary + 3-5 个短标签），写进 attachments 行',
  'group-bot-intro': '群机器人"何时叫我"说明的 system 段：让小模型代写 1-2 句话题/场景描述挂到群调度器',
  'output-mode-bubble': '注入 system 的输出模式指令（bubble）：微信气泡风格、`\\n---\\n` 分隔每个气泡',
  'output-mode-single': '注入 system 的输出模式指令（single）：一段连续文本、不用气泡分隔符',
};
