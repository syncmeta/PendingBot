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
