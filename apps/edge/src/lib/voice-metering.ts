import type { Env } from '../types';
import type { SupabaseClient } from './supabase';
import {
  computeVoiceCost,
  enqueueAudit,
  type ResolvedRoute,
} from '../llm/router';
import { getConfigInt } from './billing';
import { usdToPncMicros } from '../billing/pnc';
import { publishToHub } from './realtime-publish';

export const DEFAULT_REALTIMEKIT_AUDIO_PARTICIPANT_USD_PER_MINUTE = 0.0005;
const REALTIMEKIT_AUDIO_PRICE_KEY = 'cloudflare_realtimekit_audio_participant_usd_per_minute';

export interface RealtimeUsage {
  input_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
    cached_tokens?: number;
    cached_tokens_details?: {
      text_tokens?: number;
      audio_tokens?: number;
    };
  };
  output_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
  };
}

export interface VoiceTurnUsage {
  inputTokens: number;
  outputTokens: number;
  audioInputTokens: number;
  audioOutputTokens: number;
  cacheReadTokens: number;
}

export type VoiceAuditSource = 'voice_call' | 'group_voice_call';

interface RealtimeEventLike {
  type?: unknown;
  error?: {
    type?: unknown;
    code?: unknown;
    [key: string]: unknown;
  };
  session?: {
    id?: unknown;
    model?: unknown;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

function stringField(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

export function splitRealtimeUsage(usage: RealtimeUsage): VoiceTurnUsage {
  const inDetails = usage.input_token_details;
  const cachedText = inDetails?.cached_tokens_details?.text_tokens ?? 0;
  const cachedAudio = inDetails?.cached_tokens_details?.audio_tokens ?? 0;
  return {
    inputTokens: Math.max(0, (inDetails?.text_tokens ?? 0) - cachedText),
    outputTokens: usage.output_token_details?.text_tokens ?? 0,
    audioInputTokens: Math.max(0, (inDetails?.audio_tokens ?? 0) - cachedAudio),
    audioOutputTokens: usage.output_token_details?.audio_tokens ?? 0,
    cacheReadTokens: inDetails?.cached_tokens ?? 0,
  };
}

export function safeRealtimeEventSummary(msg: RealtimeEventLike): {
  type?: string;
  session_id?: string;
  model?: string;
} {
  return {
    type: stringField(msg.type),
    session_id: stringField(msg.session?.id),
    model: stringField(msg.session?.model),
  };
}

export function safeRealtimeErrorSummary(msg: RealtimeEventLike): {
  type?: string;
  code?: string;
} {
  return {
    type: stringField(msg.error?.type),
    code: stringField(msg.error?.code),
  };
}

export async function getRealtimeKitAudioParticipantUsdPerMinute(
  supa: SupabaseClient,
): Promise<number> {
  const configured = await getConfigInt(supa, REALTIMEKIT_AUDIO_PRICE_KEY);
  return configured != null && configured >= 0
    ? configured
    : DEFAULT_REALTIMEKIT_AUDIO_PARTICIPANT_USD_PER_MINUTE;
}

export function computeRealtimeKitParticipantCostUsd(
  participantSeconds: number,
  usdPerParticipantMinute: number,
): number {
  if (!Number.isFinite(participantSeconds) || participantSeconds <= 0) return 0;
  if (!Number.isFinite(usdPerParticipantMinute) || usdPerParticipantMinute <= 0) return 0;
  return (participantSeconds / 60) * usdPerParticipantMinute;
}

export async function enqueueVoiceTurnAudit(input: {
  env: Env;
  route: ResolvedRoute;
  userId: string;
  conversationId: string;
  usage: VoiceTurnUsage;
  source: VoiceAuditSource;
  botId: string;
  turnIndex: number;
  startedAt?: number;
  sessionId?: string;
  roomId?: string;
  presentUserIds?: string[];
}): Promise<string> {
  return enqueueAudit(input.env, input.route, {
    userId: input.userId,
    conversationId: input.conversationId,
    taskType: 'voice_call',
    startedAt: input.startedAt ?? Date.now(),
    status: 'success',
    ...input.usage,
    metadata: {
      source: input.source,
      ...(input.sessionId ? { session_id: input.sessionId } : {}),
      ...(input.roomId ? { room_id: input.roomId } : {}),
      turn_index: input.turnIndex,
      bot_id: input.botId,
      ...(input.presentUserIds ? { present_user_ids: [...input.presentUserIds] } : {}),
    },
  });
}

export async function broadcastVoiceCostPreview(input: {
  env: Env;
  supa: SupabaseClient;
  conversationId: string;
  sessionId: string;
  modelToCall: string | undefined;
  usage: VoiceTurnUsage;
  cumulativePncMicros: number;
  logPrefix: string;
  atMs?: number;
}): Promise<number> {
  const usd = computeVoiceCost(input.modelToCall, input.usage);
  if (usd == null) return input.cumulativePncMicros;

  try {
    // Preview must match the actual debit exactly: pnc_micros via
    // usdToPncMicros (the same converter router.ts / realtime-meter.ts use
    // to debit the WalletDO) and NO runtime markup — markup only applies on
    // the Polar pack sell side, never to live vendor cost. This keeps the
    // running figure the user sees in-call identical in unit and amount to
    // what their wallet drains, so the hang-up reconciliation matches.
    const delta = usdToPncMicros(usd);
    if (delta <= 0) return input.cumulativePncMicros;
    const cumulativePncMicros = input.cumulativePncMicros + delta;
    await publishToHub(input.env, `conv:${input.conversationId}`, {
      type: 'voice_cost',
      conversation_id: input.conversationId,
      session_id: input.sessionId,
      delta_pnc_micros: delta,
      cumulative_pnc_micros: cumulativePncMicros,
      at_ms: input.atMs ?? Date.now(),
    });
    return cumulativePncMicros;
  } catch (err) {
    console.warn(`${input.logPrefix} broadcast cost failed`, err);
    return input.cumulativePncMicros;
  }
}
