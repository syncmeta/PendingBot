import type { Dictionary } from '../types';

// 源语言。所有 key 必须先在这里出现，其它 locale 是它的翻译。
// 路由错误消息等 user-facing 字符串收拢到这里 — PR 中后续批量迁移。
const zh: Dictionary = {
  // 语音通话路由错误消息（apps/edge/src/routes/realtime.ts）
  'voice.region_unsupported':
    '打电话要直连 OpenAI，检查你的网络是否处于它支持的国家或地区',
  'voice.bot_not_enabled': '这个 bot 还没开通语音通话',
  'voice.insufficient_balance': '余额不足，无法开始通话',
  'voice.conversation_not_found': '会话不存在',
  'voice.upstream_failed': '语音服务暂时不可用，稍后再试',
  'voice.session_not_found': '通话会话不存在或已过期',
};

export default zh;
