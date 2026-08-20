// Control protocol between RoomVoiceDO (control plane) and the group-voice
// media container (audio plane). One bidirectional WebSocket per room,
// opened by the DO to the container's /control endpoint.
//
//   DO  -> container : ControlCommand
//   container -> DO  : ControlEvent
//
// Keep this file byte-identical to the container-side copy at
// apps/voice-container/src/protocol.ts.

/** OpenAI turn-detection block (tri-state mirrors BotSpec.voiceConfig). */
export type TurnDetection =
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

/** Per-bot spec the DO hands to the container when a bot joins. */
export interface ContainerBotSpec {
  botId: string;
  model: string;
  instructions: string;
  voice: string;
  /** undefined = omit (OpenAI default); null = disable VAD; object = apply. */
  turnDetection?: TurnDetection;
  /** Realtime function tools — the DO computes these (it owns permissions). */
  tools: unknown[];
  /** RealtimeKit participant credentials for the headless bot client. */
  realtimeKit?: {
    meetingId: string;
    participantId: string;
    authToken: string;
  };
}

/** Usage block inside an OpenAI realtime `response.done` event. */
export interface RealtimeUsage {
  input_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
    cached_tokens?: number;
    cached_tokens_details?: { text_tokens?: number; audio_tokens?: number };
  };
  output_token_details?: { text_tokens?: number; audio_tokens?: number };
}

export interface MediaParticipantDiagnostic {
  kind: 'human' | 'bot';
  id: string;
  speaking: boolean;
  audioLevel: number;
  source: 'container' | 'model';
  playoutDepthMs?: number;
  underruns?: number;
  maxGapMs?: number;
  droppedOutputMs?: number;
  inputLevel?: number;
  inputFrames?: number;
  quietFrames?: number;
  realtimeKitConnected?: boolean;
  modelSessionReady?: boolean;
}

export interface MediaDiagnostics {
  atMs: number;
  participants: MediaParticipantDiagnostic[];
}

// ── DO -> container ──────────────────────────────────────────────────

export type ControlCommand =
  // Arm (or RESET) the room. `start` is idempotent: receiving it on a
  // warm/reused container instance tears down any existing bot legs +
  // timers BEFORE arming fresh, so a DO that reconnected after a control
  // drop can replay `start` + re-`add-bot` to rebuild room state cleanly
  // without double-running timers or leaking sockets (see Unit 2).
  | { t: 'start'; token: string; openaiApiKey: string }
  | { t: 'add-bot'; spec: ContainerBotSpec }
  | { t: 'remove-bot'; botId: string }
  | { t: 'update-tools'; botId: string; tools: unknown[] }
  | { t: 'tool-result'; botId: string; callId: string; output: string }
  // Heartbeat: the DO pings on a fixed cadence; the container replies
  // `pong`. A missed pong window is how the DO detects a half-open
  // control socket and triggers reconnect + resync.
  | { t: 'ping' }
  | { t: 'end' };

// ── container -> DO ──────────────────────────────────────────────────

export type ControlEvent =
  | { t: 'ready' }
  | { t: 'bot-tool'; botId: string; name: string; callId: string; args?: string }
  | { t: 'turn-usage'; botId: string; usage: RealtimeUsage }
  | { t: 'diagnostics'; diagnostics: MediaDiagnostics }
  | { t: 'leg-closed'; botId: string }
  // Reply to a `ping` — the DO records lastPongAt to keep the link live.
  | { t: 'pong' };
