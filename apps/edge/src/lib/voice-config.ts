// Shared resolver for the per-bot realtime voice/turn-detection config.
// The settings live under `bots.config.voice` (camelCase, ConfigPatch in
// routes/bots.ts is the source of truth for the shape). Both transports
// (1v1 WebRTC mint, 1v1 WebSocket meter, group voice DO) call into this
// to produce the OpenAI-shaped `audio.output.voice` + `audio.input.turn_detection`
// snippet to drop into the session config.

export type RealtimeVoiceId =
  | 'alloy'
  | 'ash'
  | 'ballad'
  | 'cedar'
  | 'coral'
  | 'echo'
  | 'marin'
  | 'sage'
  | 'shimmer'
  | 'verse';

/// Default voice OpenAI picks when none is supplied. Matches what we
/// historically hard-coded in the session-mint body.
export const DEFAULT_REALTIME_VOICE: RealtimeVoiceId = 'marin';

interface VoiceCfg {
  voiceId?: RealtimeVoiceId | null;
  turnDetection?: {
    type?: 'auto' | 'server_vad' | 'semantic_vad' | 'none';
    threshold?: number;
    prefixPaddingMs?: number;
    silenceDurationMs?: number;
    eagerness?: 'low' | 'medium' | 'high' | 'auto';
    createResponse?: boolean;
    interruptResponse?: boolean;
  };
}

/// OpenAI Realtime `audio.input.turn_detection` payload. `null` means
/// disable VAD entirely (push-to-talk); `undefined` means leave the
/// field absent so OpenAI applies its default (currently semantic_vad).
export type TurnDetectionPayload =
  | null
  | {
      type: 'server_vad' | 'semantic_vad';
      threshold?: number;
      prefix_padding_ms?: number;
      silence_duration_ms?: number;
      eagerness?: 'low' | 'medium' | 'high' | 'auto';
      create_response?: boolean;
      interrupt_response?: boolean;
    };

export interface ResolvedVoiceConfig {
  voice: RealtimeVoiceId;
  /// undefined → omit the key; null → explicitly disable VAD; object →
  /// send as-is. Callers must distinguish all three (`'turn_detection' in obj`).
  turnDetection: TurnDetectionPayload | undefined;
}

function readCfg(config: unknown): VoiceCfg | null {
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    return null;
  }
  const v = (config as Record<string, unknown>).voice;
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  return v as VoiceCfg;
}

/// Pull the resolved voice + turn_detection block out of `bots.config`.
/// Tolerant of every field being absent — the bot uses OpenAI defaults
/// throughout when nothing has been set in the UI yet.
export function resolveVoiceConfig(config: unknown): ResolvedVoiceConfig {
  const cfg = readCfg(config);
  const voice = (cfg?.voiceId ?? DEFAULT_REALTIME_VOICE) as RealtimeVoiceId;

  const td = cfg?.turnDetection;
  let turnDetection: TurnDetectionPayload | undefined;
  if (!td || !td.type || td.type === 'auto') {
    turnDetection = undefined;
  } else if (td.type === 'none') {
    turnDetection = null;
  } else if (td.type === 'server_vad') {
    turnDetection = {
      type: 'server_vad',
      ...(typeof td.threshold === 'number' && { threshold: td.threshold }),
      ...(typeof td.prefixPaddingMs === 'number' && {
        prefix_padding_ms: td.prefixPaddingMs,
      }),
      ...(typeof td.silenceDurationMs === 'number' && {
        silence_duration_ms: td.silenceDurationMs,
      }),
      ...(typeof td.createResponse === 'boolean' && {
        create_response: td.createResponse,
      }),
      ...(typeof td.interruptResponse === 'boolean' && {
        interrupt_response: td.interruptResponse,
      }),
    };
  } else {
    // semantic_vad
    turnDetection = {
      type: 'semantic_vad',
      ...(td.eagerness && { eagerness: td.eagerness }),
      ...(typeof td.createResponse === 'boolean' && {
        create_response: td.createResponse,
      }),
      ...(typeof td.interruptResponse === 'boolean' && {
        interrupt_response: td.interruptResponse,
      }),
    };
  }

  return { voice, turnDetection };
}
