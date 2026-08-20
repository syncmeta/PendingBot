import type { Dictionary } from '../types';

// English translations. Missing keys fall back to zh at runtime.
const en: Dictionary = {
  // Voice call route error messages (apps/edge/src/routes/realtime.ts)
  'voice.region_unsupported':
    'Voice calls connect directly to OpenAI. Check whether your network is in a region OpenAI supports.',
  'voice.bot_not_enabled': 'This bot does not have voice calls enabled.',
  'voice.insufficient_balance': 'Not enough balance to start a call.',
  'voice.conversation_not_found': 'Conversation not found.',
  'voice.upstream_failed': 'Voice service is temporarily unavailable. Try again shortly.',
  'voice.session_not_found': 'Call session not found or expired.',
};

export default en;
